@preconcurrency import Combine
@preconcurrency import PDFKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 弱引用包装器，用于打破全局数组对 AppState 的死锁强引用
struct WeakAppState {
    weak var value: AppState?
}

/// [教程注释：业务状态的核心引擎]
/// AppState 扮演了整个 App 的“大脑”角色。
/// 它必须是 `class` (引用类型) 并继承自 `ObservableObject`，这样它就能在内存中保持独立唯一，
/// 并且允许 SwiftUI 的各种视图去“订阅”它的状态变化。
/// 继承 `NSObject` 并且遵循 `PDFViewDelegate`，是因为底层依然用的是传统的 Objective-C 框架 PDFKit，必须使用老办法去接管它的代理回调。
final class AppState: NSObject, ObservableObject, PDFViewDelegate {
    
    // [核心概念：响应式视图容器]
    // 整个 App 最核心的组件就是这个 PDFView，它是苹果官方提供的重量级 PDF 渲染引擎。
    @Published var pdfView = CustomPDFView()
    @Published var documentVersion = UUID()
    @Published var dropTargetIndex: Int? = nil
    @Published var draggedIndices: Set<Int>? = nil
    
    // MARK: - Sub-Managers
    // [架构思想：Manager 模式解耦]
    // 最早的时候，缩略图、搜索、历史记录的代码全部堆在 AppState 里面，导致文件长达数千行，这是典型的“上帝类 (God Class)”反模式。
    // 现在，我们将特定的功能领域抽离到专门的 Manager (管理器) 中。AppState 只是持有它们。
    let thumbnailManager = ThumbnailManager()
    let searchManager = SearchManager()
    let navigationManager = NavigationManager()
    let annotationManager = AnnotationManager()
    let documentManager = DocumentManager()
    let readingTracker = ReadingTracker.shared
    
    // MARK: - Hibernation System
    // [高级功能：内存休眠系统]
    // macOS 上，PDFKit 有一个臭名昭著的机制：当你翻页时，它会不断缓存渲染好的图片，最终吃掉几个 G 的内存。
    // 我们自己实现了一个休眠机制：当应用失焦几分钟后，把 PDFView 彻底干掉释放内存，等用户点回来时再重新加载。
    @Published var isHibernating: Bool = false
    var hibernationWorkItem: DispatchWorkItem? // 用来取消延时执行的闭包任务
    // [O(1)级极速恢复] 用于保存休眠前的物理状态，使用基础数据类型避免强引用泄漏
    var hibernatedPosition: (pageIndex: Int, point: CGPoint, zoom: CGFloat)?
    var originalWindowTitle: String?
    
    // [原生内存优化] 监听操作系统的底层内存压力告警
    var memoryPressureSource: DispatchSourceMemoryPressure?
    
    #if os(macOS)
    // 弱引用宿主窗口，防止循环引用导致内存泄漏
    weak var hostingWindow: NSWindow?
    #endif
    
    // 每次重新生成 PDFView 时，给它一个新 ID，强制 SwiftUI 把它当成全新视图重新渲染。
    @Published var pdfViewId = UUID()
    
    // [教程注释：带副作用的属性监听器]
    // `didSet` 魔法：每当 activeType 的值发生变化时，大括号里的代码就会自动执行。
    // 这里用来判断：如果用户选了任何批注工具，我们就重置计时器；如果选了 none，就彻底停掉。
    @Published var activeType: AnnotationType = AnnotationType.none {
        didSet {
            if activeType != AnnotationType.none {
                applyAnnotation()
                resetAnnotationTimer()
            } else {
                stopAnnotationTimer()
            }
        }
    }
    
    // 当选中的批注改变时，立刻告诉 PDF 引擎去重绘高亮框
    @Published var selectedAnnotation: PDFAnnotation? {
        didSet {
            guard let selected = selectedAnnotation else { return }
            pdfView.setPlatformNeedsDisplay()
            handleAnnotationSelection(selected)
        }
    }
    
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    
    func L(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    
    // MARK: - Redirected Properties (属性转发)
    // [架构技巧：封装透明化]
    // 为了不改变以前 View 层的调用代码，我们将以前写在 AppState 的属性，转发 (Proxy) 给底层的 Manager。
    // 这样外部依然是 `state.fileURL` 的叫法，但实际上操作的是 `documentManager.fileURL`。
    var fileURL: URL? {
        get { documentManager.fileURL }
        set { documentManager.fileURL = newValue }
    }
    
    
    var fileName: String {
        return fileURL?.lastPathComponent ?? L("Untitled")
    }
    var documents: [PDFDocumentModel] {
        get { documentManager.documents }
        set { documentManager.documents = newValue }
    }
    var activeDocumentIndex: Int {
        get { documentManager.activeDocumentIndex }
        set { documentManager.activeDocumentIndex = newValue }
    }
    var isDirty: Bool {
        get { documentManager.isDirty }
        set { documentManager.isDirty = newValue }
    }
    
    @Published var currentPageIndex: Int = 0
    @Published var totalPageCount: Int = 0
    @Published var selectedOutline: PDFOutline?
    
    var navigationHistory: [Int] {
        get { navigationManager.navigationHistory }
        set { navigationManager.navigationHistory = newValue }
    }
    var selectedIndices: Set<Int> {
        get { navigationManager.selectedIndices }
        set { navigationManager.selectedIndices = newValue }
    }
    /// Shift+方向键连选的锚点：记录按下 Shift 时的起始页码，松开 Shift 后清除
    var shiftSelectionAnchor: Int?
    
    var allAnnotations: [PDFAnnotation] {
        get { annotationManager.allAnnotations }
        set { annotationManager.allAnnotations = newValue }
    }
    var batchStack: [UndoAction] {
        get { annotationManager.batchStack }
        set { annotationManager.batchStack = newValue }
    }
    var canUndo: Bool { annotationManager.canUndo }
    
    var underlineColor: PlatformColor {
        get { annotationManager.underlineColor }
        set { annotationManager.underlineColor = newValue }
    }
    var highlightColor: PlatformColor {
        get { annotationManager.highlightColor }
        set { annotationManager.highlightColor = newValue }
    }
    var strikeoutColor: PlatformColor {
        get { annotationManager.strikeoutColor }
        set { annotationManager.strikeoutColor = newValue }
    }
    var inkColor: PlatformColor {
        get { annotationManager.inkColor }
        set { annotationManager.inkColor = newValue }
    }
    
    // 【终极混合页面解法】：为了支持每一页大小不一的奇葩 PDF（如 PPT 混插），
    // 同时也为了杜绝 PDFKit 的多线程获取导致的白屏崩溃，我们将全书所有页面的长宽比
    // 在加载文档时的后台线程一次性全量提取，并作为一个内存只读数组供 UI 极速查询！
    @Published var pageAspectRatios: [CGFloat] = []
    
    // (Search proxy properties removed to prevent global SwiftUI over-rendering. Views now bind directly to `searchManager`.)
    
    // Internal state
    var isNavigating = false
    var isApplyingAnnotation = false
    var lastProcessedSelectionString: String?
    
    // [教程注释：计时器管理]
    // 持有 Timer 的强引用。如果它在跑的时候用户关掉窗口，我们必须在 deinit 里面手动销毁它，否则会内存泄漏！
    // 使用现代 Swift Structured Concurrency (Task) 替代容易导致内存泄漏的老旧 Timer
    var annotationTimerTask: Task<Void, Never>?
    var historyTimerTask: Task<Void, Never>?
    var annotationJumpTask: Task<Void, Never>? // 用于节约模式下防抖跳转
    var thumbnailJumpTask: Task<Void, Never>?  // 用于节约模式下缩略图导航防抖
    
    // [核心概念：Combine 的垃圾桶]
    // AnyCancellable 的集合。在使用 Combine 框架监听事件时，如果不把监听者“存”起来，它出了作用域就会立马失效。
    // 把它们全部扔进这把 Set 里，当 AppState 被销毁时，所有监听会自动取消，完美！
    var cancellables = Set<AnyCancellable>()
    
    var eventMonitor: Any? // 存 macOS 的原生事件监听器指针
    var savedDisplayMode: PDFDisplayMode = .singlePageContinuous
    
    // 静态全局变量池
    static var hasAttemptedRestore = false
    private static var _allInstances: [WeakAppState] = []
    private static let instancesQueue = DispatchQueue(label: "com.simpleview.instancesQueue")
    
    static var allInstances: [WeakAppState] {
        instancesQueue.sync { _allInstances }
    }
    
    static func addInstance(_ instance: AppState) {
        instancesQueue.sync {
            _allInstances.removeAll { $0.value == nil }
            _allInstances.append(WeakAppState(value: instance))
        }
    }
    
    static func removeInstance(_ instance: AppState) {
        instancesQueue.sync {
            _allInstances.removeAll { $0.value === instance || $0.value == nil }
        }
    }
    static var pendingRestoreURLs: [URL] = []
    static var isAppExiting = false
    
    var thumbnailUpdateSubject: PassthroughSubject<Int, Never> { thumbnailManager.thumbnailUpdateSubject }
    
    // [生命周期：对象诞生]
    override init() {
        super.init()
        // 设置自己作为各个组件的事件代理人
        self.pdfView.manager = self.annotationManager
        pdfView.delegate = self
        setupCallbacks()
        setupObservers()
        #if os(iOS)
        restoreiOSDocuments()
        #endif
        // 把自己注册到全局花名册里，并顺手清理一下死掉的僵尸对象
        AppState.addInstance(self)
    }
    
    convenience init(url: URL? = nil) {
        self.init()
        if let url = url {
            self.fileURL = url
            loadPDF(url: url)
        }
    }
    
    // [极致内存斩杀：显式清理机制]
    // 专门用来应对 PDFKit 贪婪的底层缓存策略。当窗口关闭时，我们不能仅仅依靠系统 GC，
    // 必须手动把底层的文档指针拔掉，强制 CoreGraphics 吐出几百兆的瓦片缓存。
    func cleanup() {
        // 节约模式下关闭文档时强制清空 CoreAnimation 缓存
        if MemoryMode.current.policy.aggressivePurgeOnClose {
            #if os(macOS)
            pdfView.clearSelection()
            pdfView.layoutDocumentView()
            #endif
        }
        
        pdfView.document = nil
        pdfView.removeFromSuperview()
        
        // 【终极防漏】：直接替换为全新的空壳实例！如果仅仅置 nil，底层的某些 PDFKit 视图层级可能依旧互相引用。
        // 用全新的实例替换，旧的 PDF 视图堆栈会被彻底废弃并进入系统级垃圾回收。
        pdfView = CustomPDFView()
        
        documentManager.closeAll()
        historyTimerTask?.cancel()
        annotationTimerTask?.cancel()
        annotationJumpTask?.cancel()
        thumbnailJumpTask?.cancel()
        
        // 结算阅读时长并停止追踪，防止 sessionStartTime 残留
        readingTracker.stopTracking()
        
        // [内存防漏防御：强行斩断业务数据关联]
        // 彻底清空可能对 PDFPage 和 PDFDocument 造成强引用的批注和历史记录，防止循环引用导致文档内存无法释放
        allAnnotations.removeAll()
        batchStack.removeAll()
        navigationManager.clearHistory()
        
        if MemoryMode.current.policy.aggressivePurgeOnClose {
            thumbnailManager.clearCache()
        }
        searchManager.performSearch(in: nil, pdfView: nil)
        
        // 【切断引信】：无论当前 AppState 是否被某些系统底层闭包隐性持有，
        // 在窗口关闭的这一刻，彻底斩断它所有的内部事件流监听，杜绝僵尸对象响应事件！
        cancellables.forEach { $0.cancel() }
    }
    
    // [生命周期：对象死亡]
    deinit {
        cleanup()
        
        // 当这个 State 马上要被清理出内存时，抓紧最后机会保存阅读时长和打卡标签
        if let url = fileURL {
            autoTagDocumentIfCompleted(url: url)
        }
        for doc in documents {
            autoTagDocumentIfCompleted(url: doc.url)
        }
        
        // 从全局花名册中把自己划掉
        AppState.removeInstance(self)
        if let monitor = eventMonitor {
            #if os(macOS)
            NSEvent.removeMonitor(monitor)
            #endif
        }
        
        // [内存保护] 将所有的事件监听器彻底掐断
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
    
    
    // MARK: - Manager Delegate Methods
    // 将对外的 API 完美代理 (Delegate) 给底层的 Manager，保持 AppState 对外的接口简洁如初。
    func getThumbnail(for index: Int) -> PlatformImage? { thumbnailManager.getThumbnail(for: index) }
    
    // [核心方法：请求生成缩略图]
    func generateThumbnail(for index: Int) {
        // 【终极防撞崩溃修复】绝对、永远不要在后台线程调用 PDFDocument.page(at:)！
        // Apple PDFKit 的索引查询存在极其脆弱的底层锁。如果后台在获取页面，而前台 PDFView 也在同一时刻获取页面准备渲染，
        // 将会 100% 导致 CGPDFDocument 的内部状态机死锁，进而使得整个页面永远变成一张白纸 (Blank Page Bug)！
        // 我们的解法是：趁现在我们在安全的 SwiftUI 主线程上，把这个页面对象“取出来”，然后再安全地“扔”给后台画画！
        guard let doc = pdfView.document, let page = doc.page(at: index) else { return }
        thumbnailManager.generateThumbnail(for: page, at: index, in: doc) { [weak self] currentDoc in
            return currentDoc === self?.pdfView.document
        }
}
    
    // 取消缩略图生成任务
    func cancelThumbnailGeneration(for index: Int) {
        thumbnailManager.cancelThumbnail(for: index)
    }
    
    // [智能调度] 把“即将进入视野”的缩略图提前准备好
    func prefetchThumbnails(around index: Int) {
        guard let doc = pdfView.document else { return }
        // 【内存与显示的完美平衡】
        // 之前极端缩减到前2后10，导致在 Retina 大屏幕上，可视范围内的几十个缩略图被误判为“不需要”而惨遭取消渲染（变成灰块）。
        // 现在调整为前 10 后 20（总计 30 页），既能覆盖大屏的物理可视区域，又能压制 PDFKit 一次性生成 50+ 页带来的内存暴涨。
        let start = max(0, index - 10)
        let end = min(doc.pageCount, index + 20)
        var pagesToFetch: [(Int, PDFPage)] = []
        for i in start..<end {
            if let page = doc.page(at: i) {
                pagesToFetch.append((i, page))
            }
        }
        thumbnailManager.prefetchThumbnails(pages: pagesToFetch, validRange: start...end, in: doc) { [weak self] currentDoc in
            return currentDoc === self?.pdfView.document
        }
    }
    
    // [新功能：独立对比窗口]
    // 弹出一个只有 PDFView、没有任何其他 UI 和侧边栏的纯净窗口，
    // 并且不参与任何状态同步，完全独立。
    func openCompareWindow() {
        guard let currentDoc = self.pdfView.document, let currentPage = self.pdfView.currentPage else { return }
        
        #if os(macOS)
        // 直接绕过 SwiftUI，实例化一个极其纯净的原生 PDFView
        let purePDFView = PDFView()
        purePDFView.document = currentDoc
        purePDFView.autoScales = true
        purePDFView.displayMode = .singlePageContinuous
        purePDFView.displaysPageBreaks = true
        
        // 跳转到当前相同的页码
        purePDFView.go(to: currentPage)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(self.L("Comparison")) - \(self.fileName)"
        window.tabbingMode = .disallowed // 强制独立窗口，禁止被 macOS 自动合并为标签页
        
        window.contentView = purePDFView
        window.center() // 在屏幕正中央弹出
        
        // 添加标题栏右侧的页码显示
        let accessoryVC = NSTitlebarAccessoryViewController()
        accessoryVC.layoutAttribute = .right
        
        // 创建无边框文本框
        let pageLabel = NSTextField(labelWithString: "\(currentDoc.index(for: currentPage) + 1) / \(currentDoc.pageCount)")
        pageLabel.font = .systemFont(ofSize: 12)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.alignment = .right
        pageLabel.frame = NSRect(x: 0, y: 4, width: 80, height: 16)
        
        // 用一个透明容器来增加边距
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        container.addSubview(pageLabel)
        accessoryVC.view = container
        window.addTitlebarAccessoryViewController(accessoryVC)
        
        // 关键逻辑：防止窗口刚弹出来就被系统 ARC 自动销毁
        let windowController = CompareWindowController(window: window)
        windowController.pdfView = purePDFView
        windowController.pageLabel = pageLabel
        
        WindowRegistry.shared.add(windowController)
        
        windowController.showWindow(nil)
        #endif
    }
}

#if os(macOS)
// 专门用于对比窗口的轻量控制器，用于监听页码变化并更新标题栏，同时保证内存安全
class CompareWindowController: NSWindowController {
    weak var pdfView: PDFView?
    var pageLabel: NSTextField?
    
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
    }
    
    @objc func pageChanged() {
        if let pdfView = pdfView, let page = pdfView.currentPage, let doc = pdfView.document {
            pageLabel?.stringValue = "\(doc.index(for: page) + 1) / \(doc.pageCount)"
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
#endif

// [教程注释：多窗口焦点绑定支持]
struct AppStateKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }
}
