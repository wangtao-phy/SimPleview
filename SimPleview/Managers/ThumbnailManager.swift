import SwiftUI
@preconcurrency import PDFKit
import Combine

/// 页面状态只在主线程管理；后台只渲染独立的单页 PDF 数据。
/// 成品图像与任务寿命分开：取消任务、切换模式和休眠不丢弃有效缩略图。
@MainActor
final class ThumbnailManager: ObservableObject {
    static let displayWidth: CGFloat = 140
    private let cacheOwner = UUID()
    private var cacheGeneration: UInt = 0
    private var isSuspended = false
    private var displayScale: CGFloat = 2
    private struct WeakPage { weak var value: PDFPage? }
    private var knownPages: [Int: WeakPage] = [:]
    private var dirtyIndices = Set<Int>()
    private struct PendingSnapshot {
        let readyAt: ContinuousClock.Instant
        var isPrefetch: Bool
        let prepare: @MainActor () -> Void
    }
    private var pendingSnapshots: [Int: PendingSnapshot] = [:]
    private var snapshotTask: Task<Void, Never>?
    private var generatingIndices = Set<Int>()

    // 所有窗口共用两个后台工作线程；每个窗口最多提前准备两份快照。
    // 不能取消整个共享队列，只能取消本管理器持有的工作项。
    private static let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private var operations = [Int: (id: UUID, operation: Operation)]()
    let thumbnailUpdateSubject = PassthroughSubject<(Int, PlatformImage), Never>()
    let thumbnailInvalidatedSubject = PassthroughSubject<Int, Never>()
    let hotReloadSubject = PassthroughSubject<Void, Never>()

    isolated deinit {
        ThumbnailStore.shared.remove(owner: cacheOwner)
        for entry in operations.values { entry.operation.cancel() }
        snapshotTask?.cancel()
    }

    func getThumbnail(for index: Int) -> PlatformImage? {
        ThumbnailStore.shared.image(owner: cacheOwner, page: index)
    }

    func suspend() {
        isSuspended = true
        cancelPendingWork()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        hotReloadSubject.send()
    }

    /// 旧图继续显示，新图完成后原位替换；离屏页的脏标记保留到下次请求。
    func invalidateThumbnail(at index: Int) {
        cancelThumbnail(for: index)
        dirtyIndices.insert(index)
        thumbnailInvalidatedSubject.send(index)
    }

    /// 仅文档替换、显示内容整体改变或关闭时彻底清空。
    func clearCache() {
        cancelPendingWork()
        knownPages.removeAll(); dirtyIndices.removeAll()
        ThumbnailStore.shared.remove(owner: cacheOwner)
    }

    private func cancelPendingWork() {
        cacheGeneration &+= 1
        snapshotTask?.cancel(); snapshotTask = nil
        pendingSnapshots.removeAll()
        for entry in operations.values { entry.operation.cancel() }
        operations.removeAll(); generatingIndices.removeAll()
    }

    /// 用页面对象身份重新定位缓存。弱引用不延长被删除页面或旧文档的寿命。
    func reconcile(with document: PDFDocument) {
        cancelPendingWork()
        var positions: [ObjectIdentifier: Int] = [:]
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { positions[ObjectIdentifier(page)] = index }
        }
        var mapping: [Int: Int] = [:]
        var retained: [Int: WeakPage] = [:]
        for (oldIndex, weakPage) in knownPages {
            guard let page = weakPage.value, let index = positions[ObjectIdentifier(page)] else { continue }
            mapping[oldIndex] = index; retained[index] = weakPage
        }
        ThumbnailStore.shared.remap(owner: cacheOwner, pages: mapping)
        dirtyIndices = Set(dirtyIndices.compactMap { mapping[$0] })
        knownPages = retained
    }

    /// 按侧栏宽度 × 屏幕倍率生成真实像素；长宽比与旋转保持不变。
    /// 极窄长页限制最大边长，防止异常页面尺寸造成无上限的位图分配。
    static func pixelSize(bounds: CGRect, rotation: Int, scale: CGFloat) -> CGSize? {
        let rotated = abs(rotation % 180) == 90
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        guard width.isFinite, height.isFinite, width > 0, height > 0, scale.isFinite, scale > 0 else { return nil }
        let pixelWidth = ceil(displayWidth * scale)
        let pixelHeight = ceil(pixelWidth * height / width)
        guard pixelWidth.isFinite, pixelHeight.isFinite else { return nil }
        let factor = min(1, 2048 / max(pixelWidth, pixelHeight))
        return CGSize(width: max(1, floor(pixelWidth * factor)), height: max(1, floor(pixelHeight * factor)))
    }

    func generateThumbnail(for page: PDFPage, at index: Int, in doc: PDFDocument, prefetch: Bool = false,
                           currentDocChecker: @escaping @MainActor @Sendable () -> Bool) {
        guard !isSuspended, let size = Self.pixelSize(bounds: page.bounds(for: .cropBox), rotation: page.rotation, scale: displayScale) else { return }
        knownPages[index] = WeakPage(value: page)
        if generatingIndices.contains(index) {
            if !prefetch { pendingSnapshots[index]?.isPrefetch = false }
            return
        }
        if !dirtyIndices.contains(index), ThumbnailStore.shared.contains(owner: cacheOwner, page: index, pixels: size) { return }
        if pendingSnapshots.count + operations.count >= 60 { cancelPendingWork() }
        generatingIndices.insert(index)
        pendingSnapshots[index] = PendingSnapshot(readyAt: .now, isPrefetch: prefetch) { [weak self, weak page, weak doc] in
            guard let self else { return }
            guard let page, let doc, page.document === doc, currentDocChecker() else {
                self.markAsFinished(index, id: nil); return
            }
            self.enqueueThumbnail(for: page, at: index, size: size, currentDocChecker: currentDocChecker)
        }
        scheduleNextSnapshot()
    }

    /// 只预取视口前后两页。切换到高倍率屏幕时保留旧图，逐页补齐清晰图像。
    func updateViewport(_ indices: [Int], in document: PDFDocument, displayScale: CGFloat = 2,
                        currentDocChecker: @escaping @MainActor @Sendable () -> Bool) {
        if displayScale.isFinite, displayScale > 0, self.displayScale != displayScale {
            self.displayScale = displayScale
            cancelPendingWork()
        }
        let visible = Set(indices.filter { $0 >= 0 && $0 < document.pageCount })
        ThumbnailStore.shared.setVisible(visible, owner: cacheOwner)
        var wanted = visible
        for index in visible { wanted.formUnion(max(0, index - 2)...min(document.pageCount - 1, index + 2)) }
        for index in generatingIndices.subtracting(wanted) { cancelThumbnail(for: index) }
        for index in visible.sorted() + wanted.subtracting(visible).sorted() {
            guard let page = document.page(at: index) else { continue }
            generateThumbnail(for: page, at: index, in: document, prefetch: !visible.contains(index), currentDocChecker: currentDocChecker)
        }
    }

    private func scheduleNextSnapshot() {
        guard !isSuspended, snapshotTask == nil, operations.count < 2, !pendingSnapshots.isEmpty else { return }
        snapshotTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self else { return }
            self.snapshotTask = nil
            guard let (index, request) = self.pendingSnapshots.min(by: {
                if $0.value.isPrefetch != $1.value.isPrefetch { return !$0.value.isPrefetch }
                return $0.value.readyAt < $1.value.readyAt
            }) else { return }
            self.pendingSnapshots[index] = nil
            request.prepare()
            self.scheduleNextSnapshot()
        }
    }

    private func enqueueThumbnail(for page: PDFPage, at index: Int, size: CGSize,
                                  currentDocChecker: @escaping @MainActor @Sendable () -> Bool) {
        // 活动页面只在主线程序列化；后台不能与正文共享 PDFKit 对象及其内部缓存。
        guard let pageData = StandardInk.exportData(of: page) else { markAsFinished(index, id: nil); return }
        let showsAnnotations = page.displaysAnnotations
        let generation = cacheGeneration, operationID = UUID()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let thumb: NSImage? = autoreleasepool {
                guard let document = PDFDocument(data: pageData), let page = document.page(at: 0) else { return nil }
                // PDFPage 不拥有 PDFDocument；明确保留独立文档直到绘制结束。
                defer { withExtendedLifetime(document) {} }
                page.displaysAnnotations = showsAnnotations
                return page.platformThumbnail(of: size, for: .cropBox)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !operation.isCancelled, self.cacheGeneration == generation,
                      self.operations[index]?.id == operationID, currentDocChecker(), let thumb else { return }
                ThumbnailStore.shared.insert(thumb, owner: self.cacheOwner, page: index)
                self.dirtyIndices.remove(index)
                self.thumbnailUpdateSubject.send((index, thumb))
            }
        }
        // 被取消且尚未开始的任务不会执行工作闭包，完成回调仍必须释放调度槽位。
        operation.completionBlock = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.markAsFinished(index, id: operationID) }
        }
        operations[index] = (operationID, operation)
        Self.renderQueue.addOperation(operation)
    }

    private func markAsFinished(_ index: Int, id: UUID?) {
        if let id, operations[index]?.id != id { return }
        generatingIndices.remove(index); operations[index] = nil
        scheduleNextSnapshot()
    }

    func cancelThumbnail(for index: Int) {
        pendingSnapshots[index] = nil
        operations.removeValue(forKey: index)?.operation.cancel()
        generatingIndices.remove(index)
        if pendingSnapshots.isEmpty { snapshotTask?.cancel(); snapshotTask = nil }
        scheduleNextSnapshot()
    }
}
