import SwiftUI
import os
@preconcurrency import PDFKit
import Combine

/// [教程注释：极速缩略图引擎 (ThumbnailManager)]
/// PDF 的缩略图渲染非常耗费 CPU，如果你滚动得很快，瞬间触发几百页的渲染，主线程会当场卡死。
/// 所以我们需要一个专门的引擎，利用后台队列和缓存机制来解决这个问题。
final class ThumbnailManager: ObservableObject {
    
    private let cacheOwner = UUID()
    private var cacheGeneration: UInt = 0
    private struct PendingSnapshot {
        let readyAt: ContinuousClock.Instant
        var isPrefetch: Bool
        let prepare: @MainActor () -> Void
    }
    private var pendingSnapshots: [Int: PendingSnapshot] = [:]
    private var snapshotTask: Task<Void, Never>?
    // 防止对同一页重复发起请求；图像由 ThumbnailStore 统一持有。
    private var generatingIndices = Set<Int>()
    private let lock = OSAllocatedUnfairLock() // 采用性能最高的 OSAllocatedUnfairLock
    
    // [并发调度器]
    // 专门的渲染队列，使用 OperationQueue 支持取消。
    // 每窗口至多两张独立 PDF 快照并行，缩短整屏等待时间，
    // 不随页数增加工作线程；主线程仍每轮只准备一页。
    private let renderQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility // 侧栏缩略图不能与正文瓦片争抢交互优先级
        return q
    }()
    
    // 记录正在执行的请求，方便随时精准取消
    private var operations = [Int: (id: UUID, operation: Operation)]()
    
    // 用来通知 UI 某张图画好了的信号发射器
    let thumbnailUpdateSubject = PassthroughSubject<(Int, PlatformImage), Never>()
    let thumbnailInvalidatedSubject = PassthroughSubject<Int, Never>()
    
    // 用来通知所有存活（可见）的缩略图重新发起渲染请求（热重载唤醒机制）
    let hotReloadSubject = PassthroughSubject<Void, Never>()
    
    private var currentMemoryMode: MemoryMode
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    
    init() {
        self.currentMemoryMode = MemoryMode.current
        applyMemoryMode()
        
        // 仅监听 memoryMode 键的变化，避免任意 UserDefaults 变更都触发缓存策略重评估
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let newMode = MemoryMode.current
                if self.currentMemoryMode != newMode {
                    self.currentMemoryMode = newMode
                    self.applyMemoryMode()
                }
            }
        }
    }
    
    deinit {
        let owner = cacheOwner
        Task { @MainActor in ThumbnailStore.shared.remove(owner: owner) }
        renderQueue.cancelAllOperations()
        snapshotTask?.cancel()
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func applyMemoryMode() {
        clearCache()
        hotReloadSubject.send()
    }

    func getThumbnail(for index: Int) -> PlatformImage? {
        ThumbnailStore.shared.image(owner: cacheOwner, page: index)
    }

    func removeThumbnail(for index: Int) {
        cancelThumbnail(for: index)
        ThumbnailStore.shared.remove(owner: cacheOwner, page: index)
    }

    func handleMemoryPressure() {
        clearCache()
    }

    /// 编辑、撤销和删除只让该页缓存失效，不在主线程同步解码/绘图。
    /// 可见单元收到通知后走同一条后台管线；离屏页等再次出现时才生成。
    func invalidateThumbnail(at index: Int) {
        removeThumbnail(for: index)
        thumbnailInvalidatedSubject.send(index)
    }

    // [紧急制动]
    // 当文档关闭或页面发生大规模改变时，紧急杀掉所有正在排队画图的线程，清空一切。
    func clearCache() {
        cacheGeneration &+= 1
        snapshotTask?.cancel(); snapshotTask = nil
        pendingSnapshots.removeAll()
        renderQueue.cancelAllOperations()
        ThumbnailStore.shared.remove(owner: cacheOwner)
        lock.lock()
        operations.removeAll()
        generatingIndices.removeAll()
        lock.unlock()
    }
    
    // [核心渲染逻辑]
    func generateThumbnail(for page: PDFPage, at index: Int, in doc: PDFDocument, prefetch: Bool = false, currentDocChecker: @escaping @MainActor @Sendable () -> Bool) {
        // 1. 原子性地检查并在生成集合中注册，消除 TOCTOU 竞态
        lock.lock()
        if generatingIndices.contains(index) {
            if !prefetch { pendingSnapshots[index]?.isPrefetch = false }
            lock.unlock()
            return
        }
        generatingIndices.insert(index)
        lock.unlock()
        
        // 2. 检查是否已有缓存（getThumbnail 内部自行处理线程安全）
        if getThumbnail(for: index) != nil {
            markAsFinished(index, id: nil)
            return
        }

        // 延迟准备也计入队列上限，防止大量尚未离屏的单元积压快照任务。
        // 保留已完成缓存，只取消过时工作；旧渲染凭请求 ID 无法回填新任务。
        if pendingSnapshots.count + operations.count >= 60 {
            snapshotTask?.cancel(); snapshotTask = nil
            pendingSnapshots.removeAll()
            renderQueue.cancelAllOperations()
            operations.removeAll()
            generatingIndices = [index]
        }
        
        // 请求先登记，下一轮才准备；快速经过且已离屏的页仍可及时取消。
        // 首次可见页不再强制等 180 ms；只预取视口附近两页，不扫描整本书。
        pendingSnapshots[index] = PendingSnapshot(readyAt: .now, isPrefetch: prefetch) { [weak self, weak page, weak doc] in
            guard let self else { return }
            guard let page, let doc, page.document === doc, currentDocChecker() else {
                self.markAsFinished(index, id: nil); return
            }
            self.enqueueThumbnail(for: page, at: index, currentDocChecker: currentDocChecker)
        }
        scheduleNextSnapshot()
    }

    /// 可见范围是调度依据；提前两页填充缓存，使普通速度滚动时直接复用图像。
    /// 真正离开范围才取消任务，不能在单元刚出屏幕时把紧邻预取也一起取消。
    func updateViewport(_ indices: [Int], in document: PDFDocument,
                        currentDocChecker: @escaping @MainActor @Sendable () -> Bool) {
        let visible = Set(indices.filter { $0 >= 0 && $0 < document.pageCount })
        var wanted = visible
        for index in visible {
            wanted.formUnion(max(0, index - 2)...min(document.pageCount - 1, index + 2))
        }
        for index in generatingIndices.subtracting(wanted) { cancelThumbnail(for: index) }
        for index in visible.sorted() + wanted.subtracting(visible).sorted() {
            guard let page = document.page(at: index) else { continue }
            generateThumbnail(for: page, at: index, in: document,
                prefetch: !visible.contains(index), currentDocChecker: currentDocChecker)
        }
    }

    /// 每次至少让出 16 ms 给输入/布局；准备最多领先两个工作项。
    /// 可见页优先于预取。空闲时没有轮询，也不一次性序列化整屏页面。
    private func scheduleNextSnapshot() {
        guard snapshotTask == nil, operations.count < 2, !pendingSnapshots.isEmpty else { return }
        snapshotTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self else { return }
            self.snapshotTask = nil
            // 睡眠期间视口可能改变，执行前再选当前最需要的页面。
            guard let (index, request) = self.pendingSnapshots.min(by: {
                if $0.value.isPrefetch != $1.value.isPrefetch { return !$0.value.isPrefetch }
                return $0.value.readyAt < $1.value.readyAt
            }) else { return }
            self.pendingSnapshots[index] = nil
            request.prepare()
            self.scheduleNextSnapshot()
        }
    }

    private func enqueueThumbnail(for page: PDFPage, at index: Int,
                                  currentDocChecker: @escaping @MainActor @Sendable () -> Bool) {
        let safeCurrentDocChecker = currentDocChecker
        let maxEdge = currentMemoryMode.policy.thumbnailMaxEdge
        
        // 在文档所有者上创建单页快照，后台只打开这份独立数据。
        // 不能把当前显示的 PDFDocument/PDFPage 直接交给渲染队列。
        guard let pageData = StandardInk.exportData(of: page) else {
            markAsFinished(index, id: nil)
            return
        }

        let showsAnnotations = page.displaysAnnotations
        let generation = cacheGeneration
        let operationID = UUID()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self = self, let operation = operation, !operation.isCancelled else {
                DispatchQueue.main.async { self?.markAsFinished(index, id: operationID) }
                return
            }
            
            // 3. 及时释放内存 (极其重要)
            autoreleasepool {
                // [极其关键的卡顿修复]
                // 在后台线程提取 page，彻底消除主线程因为初次解析 PDF 页面对象引发的严重掉帧！
                guard let safeDoc = PDFDocument(data: pageData), let safePage = safeDoc.page(at: 0) else {
                    DispatchQueue.main.async { self.markAsFinished(index, id: operationID) }
                    return
                }
                
                safePage.displaysAnnotations = showsAnnotations

                // 4. 执行高性能渲染，按页面原始比例动态计算目标尺寸
                let pageBounds = safePage.bounds(for: .cropBox)
                guard pageBounds.width.isFinite, pageBounds.height.isFinite,
                      pageBounds.width > 0, pageBounds.height > 0 else {
                    DispatchQueue.main.async { self.markAsFinished(index, id: operationID) }
                    return
                }
                // 修复旋转 bug：PDF 页面旋转后 bounds 不会改变，必须根据 rotation 手动交换宽高
                let isRotated = safePage.rotation == 90 || safePage.rotation == 270
                let effectiveWidth = isRotated ? pageBounds.height : pageBounds.width
                let effectiveHeight = isRotated ? pageBounds.width : pageBounds.height
                
                // maxEdge 已经在主线程提前获取
                let targetSize: CGSize
                if effectiveWidth > effectiveHeight {
                    // 横向页面（如 PPT）
                    let scale = maxEdge / effectiveWidth
                    targetSize = CGSize(width: maxEdge, height: effectiveHeight * scale)
                } else {
                    // 竖向页面（标准 A4 等）
                    let scale = maxEdge / effectiveHeight
                    targetSize = CGSize(width: effectiveWidth * scale, height: maxEdge)
                }
                
                // 策略给出最终像素边长；此处不再次乘倍率，以免每张图膨胀到十余 MiB。
                let retinaSize = targetSize
                
                // 这里只渲染独立单页文档，不访问主视图正在编辑的 PDFPage。
                let thumb = safePage.platformThumbnail(of: retinaSize, for: .cropBox)
                
                guard !operation.isCancelled else {
                    DispatchQueue.main.async { self.markAsFinished(index, id: operationID) }
                    return
                }
                
                // 画好了，通知主线程更新 UI
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // 同一 PDFDocument 的页序也会改变；仅检查文档身份不足够。
                    // 清缓存版本、请求身份和取消状态全部通过才允许按页码回填。
                    guard !operation.isCancelled, self.cacheGeneration == generation,
                          self.operations[index]?.id == operationID, safeCurrentDocChecker() else {
                        self.markAsFinished(index, id: operationID)
                        return
                    }
                    
                    ThumbnailStore.shared.insert(thumb, owner: self.cacheOwner, page: index)
                    self.thumbnailUpdateSubject.send((index, thumb))
                    self.markAsFinished(index, id: operationID)
                }
            }
        }
        
        lock.lock()
        operations[index] = (operationID, operation)
        lock.unlock()
        
        renderQueue.addOperation(operation)
    }
    
    private func markAsFinished(_ index: Int, id: UUID?) {
        lock.lock()
        if let id, operations[index]?.id != id {
            lock.unlock()
            return
        }
        generatingIndices.remove(index)
        operations.removeValue(forKey: index)
        lock.unlock()
        scheduleNextSnapshot()
    }
    
    // [极限内存优化：精准击杀滞后任务]
    // 当缩略图因为用户快速滚动而离开屏幕时，如果它还在排队渲染，直接将其取消，节约宝贵的 CPU 和内存。
    func cancelThumbnail(for index: Int) {
        if pendingSnapshots.removeValue(forKey: index) != nil {
            generatingIndices.remove(index)
        }
        lock.lock()
        if let entry = operations[index] {
            entry.operation.cancel()
            operations.removeValue(forKey: index)
            generatingIndices.remove(index)
        }
        lock.unlock()
        if pendingSnapshots.isEmpty {
            snapshotTask?.cancel(); snapshotTask = nil
        }
        scheduleNextSnapshot()
    }

}
