import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// [Swift 6 新特性：Typed Throws]
/// 签名模块的专用错误类型。利用 Swift 6 的 Typed Throws 特性，
/// 在 catch 块中编译器能自动推断具体错误类型，支持穷举匹配。
enum SignatureError: Error, LocalizedError {
    case importFailed(underlying: any Error)
    case loadFailed(underlying: any Error)
    case deleteFailed(underlying: any Error)
    
    var errorDescription: String? {
        switch self {
        case .importFailed(let e): "Failed to import signature: \(e.localizedDescription)"
        case .loadFailed(let e): "Failed to load signatures: \(e.localizedDescription)"
        case .deleteFailed(let e): "Failed to delete signature: \(e.localizedDescription)"
        }
    }
}

/// 统一的日志输出器，替代散落的 print()
extension Logger {
    static let signature = Logger(subsystem: "com.tau.SimPleview", category: "Signature")
}

/// [教程注释：文件职责]
/// 这是整个 App 的底层基石之一，存放了基础的数据结构（模型 Models）、状态定义以及多语言字典。
/// 在基于 SwiftUI 的现代开发中，将与具体视图（View）无关的数据结构和枚举独立存放，是一个极佳的架构习惯。
/// 这样能让代码在不同模块中安全复用，并保持视图层的极致轻量。

/// [教程注释：枚举与配置]
/// `enum` (枚举) 配合 `CaseIterable` 协议是极其常见的技巧。
/// `CaseIterable` 会自动合成 `AppLanguage.allCases`，这让我们可以直接在视图的 `ForEach` 或 `Picker` 中遍历所有选项。
enum AppLanguage: String, CaseIterable {
    case zh, en
    
    // [核心概念：计算属性]
    // 这不是一个普通的变量，而是计算属性 (Computed Property)。它不占用额外的内存存储，每次调用都会实时走 switch 逻辑返回结果。
    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// [教程注释：内存运行模式]
/// 性能模式：保留庞大的图形缓存池，追求极限顺滑。
/// 节约模式：积极销毁未使用资源，维持低内存占用基准线。
enum MemoryMode: String, CaseIterable {
    case performance, saving
    
    var displayName: String {
        switch self {
        case .performance: return L.s("Performance", AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "zh") ?? .zh)
        case .saving: return L.s("Saving", AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "zh") ?? .zh)
        }
    }
    
    // [专家级架构重构：状态防死锁机制]
    // 之前版本为了“性能”在这里引入了 `os_unfair_lock` / `NSLock` 来维护一个静态缓存。
    // 但当 UI (如 SettingsGeneralView) 通过 `@AppStorage` 修改模式时，系统会触发 KVO 和 Notification。
    // 如果后台线程在同一微秒因为通知唤醒并试图获取锁，就会引发典型的“重入死锁 (Reentrancy Deadlock)”，导致界面彻底卡死闪退。
    // 事实证明：Apple 的 `UserDefaults.standard` 底层 (CFPreferences) 已经用 C++ 实现了极致性能的共享内存映射，
    // 读取一次仅需不到 1 微秒，并且绝对保证线程安全。因此直接透传读取，是既安全又极速的终极方案。
    nonisolated static var current: MemoryMode {
        let raw = UserDefaults.standard.string(forKey: "memoryMode") ?? "saving"
        return MemoryMode(rawValue: raw) ?? .saving
    }
    
    var policy: MemoryPolicy {
        switch self {
        case .performance: return PerformanceMemoryPolicy()
        case .saving: return SavingMemoryPolicy()
        }
    }
    
    // [过期废弃] 未来尽量直接读取 current.policy，而不是判断 isPerformance
    static var isPerformance: Bool { current == .performance }
}

/// [教程注释：标注类型]
/// 统一定义 App 支持的所有 PDF 标注类型，避免在代码里写死字符串（Magic Strings）。
enum AnnotationType: String, CaseIterable {
    case none, highlight, underline, strikeout, ink
}

/// [教程注释：多语言简易实现]
/// 结构体 `L` (Localization) 提供了一个硬编码的多语言词典方案。
/// 对于小型独立 App 来说，这比配置官方的 Localizable.strings 更加直观和容易修改。
struct L {
    // [逻辑流程]
    // 静态方法 (static func)：不需要实例化 L 即可调用。例如 `L.s("Save", .zh)`。
    // 如果字典里找不到对应的语言翻译，则使用 `??` (Nil-Coalescing Operator) 降级返回原 Key。
    // [P0修复] 将字典提升为 static let，避免每次调用都重新创建 100+ 条目的字典
    private static let dict: [String: [AppLanguage: String]] = [
            "Thumbnails": [.zh: "缩略图", .en: "Thumbnails"],
            "Outline": [.zh: "目录", .en: "Outline"],
            "Annotations": [.zh: "标注", .en: "Annotations"],
            "Search": [.zh: "搜索", .en: "Search"],
            "Record": [.zh: "记录", .en: "Record"],
            "Reading Record": [.zh: "阅读记录", .en: "Reading Record"],
            "Enable Reading Record": [.zh: "开启阅读记录", .en: "Enable Reading Record"],
            "Heatmap Granularity": [.zh: "热点图精细度", .en: "Heatmap Granularity"],
            "Heatmap Color": [.zh: "热点图颜色", .en: "Heatmap Color"],
            "Rating Chart Color": [.zh: "评分图颜色", .en: "Rating Chart Color"],
            "Reading Heatmap": [.zh: "阅读热点图", .en: "Reading Heatmap"],
            "Article Date": [.zh: "文章日期", .en: "Article Date"],
            "Authors": [.zh: "作者", .en: "Authors"],
            "Author Name": [.zh: "作者姓名", .en: "Author Name"],
            "Author Bio": [.zh: "作者简介", .en: "Author Bio"],
            "Add Author": [.zh: "添加作者", .en: "Add Author"],
            "Article Summary": [.zh: "文章总结", .en: "Article Summary"],
            "Rating": [.zh: "评分", .en: "Rating"],
            "Score (0-100)": [.zh: "分数 (0-100)", .en: "Score (0-100)"],
            "Coming soon...": [.zh: "即将推出...", .en: "Coming soon..."],
            "Save Location": [.zh: "保存位置", .en: "Save Location"],
            "Change...": [.zh: "更改...", .en: "Change..."],
            "Select": [.zh: "选择", .en: "Select"],
            "Total Time": [.zh: "总时长", .en: "Total Time"],
            "No Reading Record": [.zh: "暂无阅读记录", .en: "No Reading Record"],
            "none": [.zh: "选择", .en: "Select"],
            "highlight": [.zh: "高亮", .en: "Highlight"],
            "underline": [.zh: "下划线", .en: "Underline"],
            "strikeout": [.zh: "删除线", .en: "Strikeout"],
            "ink": [.zh: "手写", .en: "Ink"],
            "Insert Blank Page After": [.zh: "在后插入空白页", .en: "Insert Blank Page After"],
            "Insert PDF Before...": [.zh: "在此前插入 PDF...", .en: "Insert PDF Before..."],
            "Insert PDF After...": [.zh: "在此后插入 PDF...", .en: "Insert PDF After..."],
            "Delete Page": [.zh: "删除此页", .en: "Delete Page"],
            "Delete Selected Pages": [.zh: "删除选中页", .en: "Delete Selected Pages"],
            "Open...": [.zh: "打开...", .en: "Open..."],
            "Find...": [.zh: "查找...", .en: "Find..."],
            "Toggle Left Sidebar": [.zh: "切换左侧边栏", .en: "Toggle Left Sidebar"],
            "Toggle Right Sidebar": [.zh: "切换右侧边栏", .en: "Toggle Right Sidebar"],
            "Undo": [.zh: "撤销", .en: "Undo"],
            "Save": [.zh: "保存", .en: "Save"],
            "Close Window": [.zh: "关闭窗口", .en: "Close Window"],
            "Page": [.zh: "页", .en: "Page"],
            "Page Number Input": [.zh: "第 %@ 页", .en: "Page %@"],
            "Search Document...": [.zh: "搜索文档...", .en: "Search Document..."],
            "No PDF Opened": [.zh: "未打开 PDF", .en: "No PDF Opened"],
            "Open File Description": [.zh: "使用 Cmd+O 打开新文件", .en: "Use Cmd+O to open a file"],
            "iOS Open File Description": [.zh: "点击下方按钮打开文件", .en: "Tap the button below to open"],
            "Open File": [.zh: "打开文件", .en: "Open File"],
            "Language": [.zh: "语言", .en: "Language"],
            "Switch Language": [.zh: "切换语言", .en: "Switch Language"],
            "Annotation Editor": [.zh: "调整标注", .en: "Edit Annotation"],
            "Delete Annotation": [.zh: "删除标注", .en: "Delete Annotation"],
            "Done": [.zh: "完成", .en: "Done"],
            "Core Features": [.zh: "核心功能", .en: "Core"],
            "Color Selection": [.zh: "颜色选择", .en: "Colors"],
            "Annotation Tools": [.zh: "标注工具", .en: "Tools"],
            "Customize Toolbar": [.zh: "定制工具栏", .en: "Customize Toolbar"],
            "Settings": [.zh: "设置", .en: "Settings"],
            "Memory Mode": [.zh: "内存模式", .en: "Memory Mode"],
            "Performance": [.zh: "性能", .en: "High"],
            "Saving": [.zh: "节约", .en: "Low"],
            "Hibernation Timeout": [.zh: "窗口休眠时间", .en: "Hibernation Timeout"],
            "Minutes": [.zh: "分钟", .en: "Minutes"],
            "Never": [.zh: "从不", .en: "Never"],
            "New File Opens In": [.zh: "新文件打开方式", .en: "New File Opens In"],
            "New Window": [.zh: "新窗口", .en: "New Window"],
            "New Tab": [.zh: "新标签页", .en: "New Tab"],
            "Window Hibernating": [.zh: "窗口已休眠以节省内存", .en: "Window Hibernating"],
            "Click anywhere to wake up and restore memory": [.zh: "点击任意位置唤醒并恢复文件", .en: "Click anywhere to wake up and restore memory"],
            "Show Toolbar Groups": [.zh: "显示工具栏组", .en: "Show Toolbar Groups"],
            "Blue": [.zh: "蓝色", .en: "Blue"],
            "Red": [.zh: "红色", .en: "Red"],
            "Yellow": [.zh: "黄色", .en: "Yellow"],
            "Green": [.zh: "绿色", .en: "Green"],
            "Purple": [.zh: "紫色", .en: "Purple"],
            "Color": [.zh: "颜色", .en: "Color"],
            "Enter Slideshow": [.zh: "进入演示", .en: "Enter Slideshow"],
            "Exit Slideshow": [.zh: "退出演示", .en: "Exit Slideshow"],
            "Finder": [.zh: "访达", .en: "Finder"],
            "Right Column": [.zh: "右栏", .en: "Right Sidebar"],
            "Left Column": [.zh: "左栏", .en: "Left Sidebar"],
            "Import": [.zh: "导入", .en: "Import"],
            "Activate Tab": [.zh: "激活标签", .en: "Activate Tab"],
            "Close": [.zh: "关闭", .en: "Close"],
            "Close Others": [.zh: "关闭其他", .en: "Close Others"],
            "External Browser": [.zh: "外部浏览器", .en: "External Browser"],
            "Default Browser": [.zh: "默认浏览器", .en: "Default Browser"],
            "Other Application...": [.zh: "其他应用...", .en: "Other Application..."],
            "Annotation": [.zh: "标注", .en: "Annotation"],
            "Revert to Selection After": [.zh: "自动恢复选择工具", .en: "Revert to Selection After"],
            "Seconds": [.zh: "秒", .en: "Seconds"],
            "Highlight Default Color": [.zh: "高亮默认颜色", .en: "Highlight Default Color"],
            "Underline Default Color": [.zh: "下划线默认颜色", .en: "Underline Default Color"],
            "Strikeout Default Color": [.zh: "删除线默认颜色", .en: "Strikeout Default Color"],
            "General": [.zh: "通用", .en: "General"],
            "Shortcuts": [.zh: "快捷键", .en: "Shortcuts"],
            "File Operations": [.zh: "文件操作", .en: "File Operations"],
            "Navigation": [.zh: "导航", .en: "Navigation"],
            "Other Color...": [.zh: "其他颜色...", .en: "Other Color..."],
            "Global Authors Library": [.zh: "全局作者库", .en: "Global Authors Library"],
            "Works": [.zh: "个作品", .en: "Works"],
            "Select an author": [.zh: "请选择一个作者", .en: "Select an author"],
            "Name": [.zh: "姓名", .en: "Name"],
            "First Name": [.zh: "名", .en: "First Name"],
            "Last Name": [.zh: "姓", .en: "Last Name"],
            "Sort by Pinyin": [.zh: "按姓氏拼音排序", .en: "Sort by Last Name"],
            "Sort by Works Count": [.zh: "按作品数量排序", .en: "Sort by Works Count"],
            "Sort Method": [.zh: "排序方式", .en: "Sort Method"],
            "Open in Browser": [.zh: "在浏览器中打开", .en: "Open in Browser"],
            "Delete": [.zh: "删除", .en: "Delete"],
            "No authors recorded yet.": [.zh: "暂无记录的作者", .en: "No authors recorded yet."],
            "Restore Defaults": [.zh: "恢复默认设置", .en: "Restore Defaults"],
            "Signature": [.zh: "签名", .en: "Signature"],
            "Rotate Left": [.zh: "向左旋转", .en: "Rotate Left"],
            "Browser": [.zh: "浏览器打开", .en: "Browser"],
            "Comparison": [.zh: "对比查看", .en: "Comparison"],
            "Icon Only": [.zh: "仅图标", .en: "Icon Only"],
            "Icon and Text": [.zh: "图标和文本", .en: "Icon and Text"],
            "Customize Toolbar...": [.zh: "自定义工具栏...", .en: "Customize Toolbar..."]
    ]
    static func s(_ key: String, _ lang: AppLanguage) -> String {
        return dict[key]?[lang] ?? key
    }
}

/// [教程注释：搜索结果模型]
/// 遵循 `Identifiable` 协议：这是 SwiftUI 列表 (List/ForEach) 所必须的，要求每一项都有一个唯一标识符 `id`。
/// 遵循 `Equatable` 协议：使得我们可以直接用 `==` 判断两个搜索结果是否完全相同。
struct SearchMatch: Identifiable, Equatable {
    let id = UUID()
    // [极限内存优化：斩断强引用]
    // 移除了原生 `PDFSelection` 对象。因为 `PDFSelection` 会强引用 `PDFPage`，导致多达几百个搜索结果所在的 PDF 页面全部驻留内存。
    // 现在完全使用轻量级的纯数值数据结构（页码+坐标）进行通讯，内存消耗趋近于 0。
    let boundsArray: [CGRect] 
    let pageIndex: Int
    let context: String
    
    // [核心概念：自定义相等性]
    // 实现了 Equatable 协议的具体判定规则：只要两个结果的 UUID 相同，就认为是同一个结果。
    static func == (lhs: SearchMatch, rhs: SearchMatch) -> Bool { lhs.id == rhs.id }
}

/// [教程注释：核心文档模型]
/// 整个 App 的核心模型，代表了一个被打开的 PDF 文档在内存中的完整状态。
struct PDFDocumentModel: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let document: PDFDocument
    
    // 这些是可变的（var）业务属性：
    var currentPageIndex: Int = 0           // 当前阅读到的页码
    var navigationHistory: [Int] = []       // 页面跳转历史（用于实现“返回上一处”功能）
    var allAnnotations: [PDFAnnotation] = [] // 缓存所有的批注
    var batchStack: [UndoAction] = []       // 撤销堆栈（Undo/Redo 系统的核心）
    var isAccessing: Bool = false           // 标记文件安全访问权限的状态（用于 App Sandbox 环境）
    
    // [教程注释：便捷访问]
    // 通过 url 解析出不带后缀的文件名，方便 UI 直接显示标题。
    var fileName: String {
        url.deletingPathExtension().lastPathComponent
    }
    
    static func == (lhs: PDFDocumentModel, rhs: PDFDocumentModel) -> Bool {
        lhs.id == rhs.id
    }
}

/// [教程注释：撤销动作栈枚举]
/// 使用了 Swift 强大的“带关联值的枚举 (Enum with Associated Values)”。
/// 这不仅仅是个状态标志，它还能直接把当时的数据“打包”携带，完美匹配撤销重做（Undo/Redo）的设计模式。
enum UndoAction: Equatable {
    case annotation(batchID: String, pageIndices: Set<Int>)                                // 关联值是批次 ID，并携带受影响的页码集合以实现 O(K) 撤销
    case deleteAnnotation(annotations: [PDFAnnotation], pageIndices: [Int]) // 携带被删掉的标注及它们所在的页码
    case deletePage(page: PDFPage, index: Int)                              // 携带被删掉的整页对象
    case insertPages(count: Int, startIndex: Int)
    case reorderPages(originalIndices: [Int], insertedAt: Int)
    
    // [逻辑流程]
    // 当我们需要比较栈顶动作时，Swift 允许我们使用模式匹配 (Pattern Matching) 解包关联值并进行比较。
    static func == (lhs: UndoAction, rhs: UndoAction) -> Bool {
        switch (lhs, rhs) {
        case (.annotation(let id1, let p1), .annotation(let id2, let p2)): return id1 == id2 && p1 == p2
        case (.deleteAnnotation(let a1, _), .deleteAnnotation(let a2, _)): return a1 == a2
        case (.deletePage(_, let i1), .deletePage(_, let i2)): return i1 == i2
        case (.insertPages(let c1, let s1), .insertPages(let c2, let s2)): return c1 == c2 && s1 == s2
        case (.reorderPages(let o1, let i1), .reorderPages(let o2, let i2)): return o1 == o2 && i1 == i2
        default: return false
        }
    }
}

/// [教程注释：拖拽与类型系统扩展]
/// 为统一类型标识符 (Uniform Type Identifiers, UTType) 添加自定义类型。
/// 这个扩展用于实现我们 App 内部的 PDF 页面拖拽重排功能，操作系统依靠这个标识符来识别我们在拖拽什么。
extension UTType {
    static var pdfPageIndex = UTType(exportedAs: "com.simpleview.pageindex")
}

/// [教程注释：聚焦状态焦点传递机制]
/// 下面的代码是 SwiftUI 中高级的焦点值传递系统 (`FocusedValue`)。
/// 作用：当 App 处于多窗口状态时，系统可以通过 `FocusedValues` 知道用户当前正在与哪个窗口 (UIState) 交互。
/// 这样全局菜单栏（Menu Bar）的快捷键命令就能准确地下发给当前“拥有焦点”的那个窗口。
struct FocusedUIStateKey: FocusedValueKey {
    typealias Value = UIState
}

extension FocusedValues {
    // 为环境变量 `@FocusedValue(\.uiState)` 注册便捷访问路径
    var uiState: UIState? {
        get { self[FocusedUIStateKey.self] }
        set { self[FocusedUIStateKey.self] = newValue }
    }
}
