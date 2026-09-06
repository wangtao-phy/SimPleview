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
    private var prefetchPausedUntil = Date.distantPast
    // 防止对同一页重复发起请求；图像由 ThumbnailStore 统一持有。
    private var generatingIndices = Set<Int>()
    private let lock = OSAllocatedUnfairLock() // 采用性能最高的 OSAllocatedUnfairLock
    
    // [并发调度器]
    // 专门的渲染队列，使用 OperationQueue 支持取消。
    // 独立 PDF 快照仍使用串行渲染，降低 CoreGraphics 位图分配峰值。
    private let renderQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive // 但优先级要高，因为这是可见的 UI
        return q
    }()
    
    // 记录正在执行的请求，方便随时精准取消
    private var operations = [Int: (id: UUID, operation: Operation)]()
    
    // 用来通知 UI 某张图画好了的信号发射器
    let thumbnailUpdateSubject = PassthroughSubject<(Int, PlatformImage), Never>()
    
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
        prefetchPausedUntil = Date().addingTimeInterval(30)
        clearCache()
    }

    // [极速原子化更新]
    // 当在某一页上进行批注后，不需要重绘整个文档或者走后台队列。
    // 直接在主线程迅速拉取该页当前的原生图像并强制覆盖缓存，消耗极低！
    @MainActor
    func updateLiveThumbnail(for page: PDFPage, at index: Int) {
        // 此刻的实时结果比排队中的旧快照更新，取消旧请求并移除它的提交资格。
        cancelThumbnail(for: index)
        let maxEdge = currentMemoryMode.policy.thumbnailMaxEdge
        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width.isFinite, pageBounds.height.isFinite,
              pageBounds.width > 0, pageBounds.height > 0 else { return }
        let isRotated = page.rotation == 90 || page.rotation == 270
        let effectiveWidth = isRotated ? pageBounds.height : pageBounds.width
        let effectiveHeight = isRotated ? pageBounds.width : pageBounds.height
        
        let targetSize: CGSize
        if effectiveWidth > effectiveHeight {
            let scale = maxEdge / effectiveWidth
            targetSize = CGSize(width: maxEdge, height: effectiveHeight * scale)
        } else {
            let scale = maxEdge / effectiveHeight
            targetSize = CGSize(width: effectiveWidth * scale, height: maxEdge)
        }
        
        // 策略给出最终像素边长；此处不再次乘倍率，以免每张图膨胀到十余 MiB。
        let retinaSize = targetSize
        guard let data = StandardInk.exportData(of: page), let copy = PDFDocument(data: data),
              let visiblePage = copy.page(at: 0) else { return }
        visiblePage.displaysAnnotations = page.displaysAnnotations
        let thumb = visiblePage.platformThumbnail(of: retinaSize, for: .cropBox)
        
        ThumbnailStore.shared.insert(thumb, owner: cacheOwner, page: index)

        thumbnailUpdateSubject.send((index, thumb))
    }

    // [紧急制动]
    // 当文档关闭或页面发生大规模改变时，紧急杀掉所有正在排队画图的线程，清空一切。
    func clearCache() {
        cacheGeneration &+= 1
        renderQueue.cancelAllOperations()
        ThumbnailStore.shared.remove(owner: cacheOwner)
        lock.lock()
        operations.removeAll()
        generatingIndices.removeAll()
        lock.unlock()
    }
    
    // [核心渲染逻辑]
    func generateThumbnail(for page: PDFPage, at index: Int, in doc: PDFDocument, currentDocChecker: @escaping @MainActor @Sendable () -> Bool) {
        // 1. 原子性地检查并在生成集合中注册，消除 TOCTOU 竞态
        lock.lock()
        if generatingIndices.contains(index) {
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
        
        // [极速 OOM 保护] 缩略图并发爆炸修复：
        // 疯狂滑动时可能瞬间产生几百个尚未执行的画图任务，这会导致巨大的内存排队压力。
        // 如果排队任务过多，直接把旧任务全部砍掉，只保留最新的视野范围。
        lock.lock()
        if operations.count > 60 {
            renderQueue.cancelAllOperations()
            operations.removeAll()
            generatingIndices.removeAll()
            generatingIndices.insert(index)
            // 注意这里不直接 return，允许这个最新的任务入队
        }
        lock.unlock()
        
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
    }
    
    // [极限内存优化：精准击杀滞后任务]
    // 当缩略图因为用户快速滚动而离开屏幕时，如果它还在排队渲染，直接将其取消，节约宝贵的 CPU 和内存。
    func cancelThumbnail(for index: Int) {
        lock.lock()
        if let entry = operations[index] {
            entry.operation.cancel()
            operations.removeValue(forKey: index)
            generatingIndices.remove(index)
        }
        lock.unlock()
    }
    
    // [智能预加载 (Prefetching)]
    // 当用户滚到第 10 页时，我们提前把 11-40 页的图画好。如果用户滚得很慢，他会感觉非常流畅丝滑。
    func prefetchThumbnails(pages: [(Int, PDFPage)], validRange: ClosedRange<Int>, in doc: PDFDocument, currentDocChecker: @escaping @MainActor @Sendable () -> Bool) {
        guard Date() >= prefetchPausedUntil else { return }
        lock.lock()
        // 精细控制：把队列里“距离太远”的任务强行杀掉，把有限的 CPU 让给现在正需要的页面
        // 必须彻底从追踪字典中拔除，防止僵尸任务霸占名额导致后续需要的页面无法重新触发
        let keysToCancel = operations.keys.filter { !validRange.contains($0) }
        for idx in keysToCancel {
            if let entry = operations[idx] {
                entry.operation.cancel()
            }
            operations.removeValue(forKey: idx)
            generatingIndices.remove(idx)
        }
        lock.unlock()
        
        for (i, page) in pages {
            generateThumbnail(for: page, at: i, in: doc, currentDocChecker: currentDocChecker)
        }
    }
}
