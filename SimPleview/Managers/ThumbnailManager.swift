import SwiftUI
import PDFKit
import Combine

/// 解决 Swift 6 中非 Sendable 类型弱引用捕获的问题
final class WeakPDFBox: @unchecked Sendable {
    nonisolated(unsafe) private let docTable = NSHashTable<PDFDocument>.weakObjects()
    nonisolated(unsafe) private let pageTable = NSHashTable<PDFPage>.weakObjects()
    
    nonisolated var doc: PDFDocument? { docTable.allObjects.first }
    nonisolated var page: PDFPage? { pageTable.allObjects.first }
    
    init(doc: PDFDocument?, page: PDFPage?) {
        if let doc = doc { docTable.add(doc) }
        if let page = page { pageTable.add(page) }
    }
}

/// [教程注释：极速缩略图引擎 (ThumbnailManager)]
/// PDF 的缩略图渲染非常耗费 CPU，如果你滚动得很快，瞬间触发几百页的渲染，主线程会当场卡死。
/// 所以我们需要一个专门的引擎，利用后台队列和缓存机制来解决这个问题。
final class ThumbnailManager: ObservableObject {
    
    // [原生缓冲池：重新采用稳定可靠的 NSCache]
    // NSCache 是苹果提供的线程安全缓存，原生支持自动响应内存警告。
    private let nscache = NSCache<NSNumber, PlatformImage>()
    
    // [强引用护城河 (性能模式专用)]
    // 为了防止在“性能模式”下，系统因为 App 闲置而自动清空 NSCache 导致图片变灰，
    // 我们用一个普通的字典来强行“保活”最近的图片，这就叫“双重保险”。
    private var strongCache = [Int: PlatformImage]()
    private var strongKeys = [Int]() // FIFO 记录放入顺序
    private var strongKeySet = Set<Int>() // [P2优化] O(1) 去重判断
    private var strongLimit: Int = 0
    
    // 防止对同一页重复发起渲染请求，同时保护 strongCache 不被多线程同时写入
    private var generatingIndices = Set<Int>()
    private let lock = NSLock() // 恢复最轻量的常规锁，不再需要递归锁
    
    // [并发调度器]
    // 专门的渲染队列，使用 OperationQueue 支持取消。
    // maxConcurrentOperationCount = 2：限制最多只能有两个线程同时画缩略图，防止 CPU 瞬间 100% 把电池抽干
    private let renderQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInteractive // 但优先级要高，因为这是可见的 UI
        return q
    }()
    
    // 记录正在执行的请求，方便随时精准取消
    private var operations = [Int: Operation]()
    
    // 用来通知 UI 某张图画好了的信号发射器
    let thumbnailUpdateSubject = PassthroughSubject<Int, Never>()
    
    private var currentMemoryMode: MemoryMode
    
    init() {
        self.currentMemoryMode = MemoryMode.current
        applyMemoryMode()
        
        // 仅监听 memoryMode 键的变化，避免任意 UserDefaults 变更都触发缓存策略重评估
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
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
    
    private func applyMemoryMode() {
        lock.lock()
        defer { lock.unlock() }
        
        let policy = currentMemoryMode.policy
        nscache.countLimit = policy.thumbnailCountLimit
        strongLimit = policy.usesStrongCacheRetention ? policy.thumbnailCountLimit : 0
        
        // 缩容修剪：如果从性能模式切到了节约模式，立刻砍掉溢出的多余强引用
        while strongKeys.count > strongLimit {
            let oldest = strongKeys.removeFirst()
            strongKeySet.remove(oldest)
            strongCache.removeValue(forKey: oldest)
        }
    }
    
    func getThumbnail(for index: Int) -> PlatformImage? {
        // 首选去原生 NSCache 里拿（它最快，内部已处理好多线程安全）
        if let img = nscache.object(forKey: NSNumber(value: index)) {
            return img
        }
        // 如果 NSCache 被系统清空了，尝试去强引用池里拿
        lock.lock()
        defer { lock.unlock() }
        return strongCache[index]
    }
    
    func removeThumbnail(for index: Int) {
        nscache.removeObject(forKey: NSNumber(value: index))
        lock.lock()
        defer { lock.unlock() }
        strongCache.removeValue(forKey: index)
        strongKeys.removeAll { $0 == index }
        strongKeySet.remove(index)
    }
    
    // [紧急制动]
    // 当文档关闭或页面发生大规模改变时，紧急杀掉所有正在排队画图的线程，清空一切。
    func clearCache() {
        renderQueue.cancelAllOperations()
        nscache.removeAllObjects()
        lock.lock()
        operations.removeAll()
        strongCache.removeAll()
        strongKeys.removeAll()
        strongKeySet.removeAll()
        generatingIndices.removeAll()
        lock.unlock()
    }
    
    // [核心渲染逻辑]
    func generateThumbnail(for page: PDFPage, at index: Int, in doc: PDFDocument, currentDocChecker: @escaping (PDFDocument) -> Bool) {
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
            markAsFinished(index)
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
            // 注意这里不直接 return，允许这个最新的任务入队
        }
        lock.unlock()
        
        // [内存泄漏终极修复]：必须使用 WeakPDFBox 弱引用 doc 和 page！
        // 否则 Swift 的闭包会死死抓住这几百个非 Sendable 的 PDFPage 对象不放，
        // 导致用户哪怕关掉了文档，内存里依然残留几百 MB 的 PDF 无法被释放！
        let box = WeakPDFBox(doc: doc, page: page)
        nonisolated(unsafe) let safeCurrentDocChecker = currentDocChecker
        let maxEdge = currentMemoryMode.policy.thumbnailMaxEdge
        
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self = self, let operation = operation, !operation.isCancelled else {
                DispatchQueue.main.async { self?.markAsFinished(index) }
                return
            }
            
            // 安全解包弱引用的文档和页面
            guard let safeDoc = box.doc, let safePage = box.page, safeCurrentDocChecker(safeDoc) else {
                DispatchQueue.main.async { self.markAsFinished(index) }
                return
            }
            
            // 3. 及时释放内存 (极其重要)
            // CoreGraphics 渲染图像会产生巨大的临时内存堆积，autoreleasepool 保证每画完一张图瞬间把垃圾扔掉。
            autoreleasepool {
                
                // 4. 执行高性能渲染，按页面原始比例动态计算目标尺寸
                let pageBounds = safePage.bounds(for: .cropBox)
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
                
                let thumb = safePage.platformThumbnail(of: targetSize, for: .cropBox)
                
                guard !operation.isCancelled else {
                    DispatchQueue.main.async { self.markAsFinished(index) }
                    return
                }
                
                // 画好了，通知主线程更新 UI
                nonisolated(unsafe) let mainSafeDoc = safeDoc
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, safeCurrentDocChecker(mainSafeDoc) else { return }
                    
                    // 1. 存入安全的原生 NSCache
                    self.nscache.setObject(thumb, forKey: NSNumber(value: index))
                    
                    // 2. 存入强引用护城河 (仅当开启保活时才存入)
                    self.lock.lock()
                    if self.strongLimit > 0 {
                        self.strongCache[index] = thumb
                        // [P2优化] 使用 Set 进行 O(1) 去重判断
                        if self.strongKeySet.insert(index).inserted {
                            self.strongKeys.append(index)
                        }
                        while self.strongKeys.count > self.strongLimit {
                            let oldest = self.strongKeys.removeFirst()
                            self.strongKeySet.remove(oldest)
                            self.strongCache.removeValue(forKey: oldest)
                        }
                    }
                    self.lock.unlock()
                    
                    self.thumbnailUpdateSubject.send(index)
                    self.markAsFinished(index)
                }
            }
        }
        
        lock.lock()
        operations[index] = operation
        lock.unlock()
        
        renderQueue.addOperation(operation)
    }
    
    private func markAsFinished(_ index: Int) {
        lock.lock()
        generatingIndices.remove(index)
        operations.removeValue(forKey: index)
        lock.unlock()
    }
    
    // [极限内存优化：精准击杀滞后任务]
    // 当缩略图因为用户快速滚动而离开屏幕时，如果它还在排队渲染，直接将其取消，节约宝贵的 CPU 和内存。
    func cancelThumbnail(for index: Int) {
        lock.lock()
        if let operation = operations[index] {
            operation.cancel()
            operations.removeValue(forKey: index)
            generatingIndices.remove(index)
        }
        lock.unlock()
    }
    
    // [智能预加载 (Prefetching)]
    // 当用户滚到第 10 页时，我们提前把 11-40 页的图画好。如果用户滚得很慢，他会感觉非常流畅丝滑。
    func prefetchThumbnails(pages: [(Int, PDFPage)], validRange: ClosedRange<Int>, in doc: PDFDocument, currentDocChecker: @escaping (PDFDocument) -> Bool) {
        lock.lock()
        // 精细控制：把队列里“距离太远”的任务强行杀掉，把有限的 CPU 让给现在正需要的页面
        // 必须彻底从追踪字典中拔除，防止僵尸任务霸占名额导致后续需要的页面无法重新触发
        let keysToCancel = operations.keys.filter { !validRange.contains($0) }
        for idx in keysToCancel {
            if let operation = operations[idx] {
                operation.cancel()
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
