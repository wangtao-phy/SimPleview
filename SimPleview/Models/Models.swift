import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import os


/// 统一的日志输出器，替代散落的 print()
extension Logger {
    nonisolated static let view = Logger(subsystem: "com.tau.SimPleview", category: "View")
}

/// 应用级选项；翻译字典位于 Localization.swift，编辑历史动作位于 UndoAction.swift。
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

/// PDF 页面护眼背景色枚举
enum PDFPageBackgroundColor: Int, CaseIterable, Codable {
    case `default` = 0
    case green = 1
    case yellow = 2
    case black = 3
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
