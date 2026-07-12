import SwiftUI
import UniformTypeIdentifiers
import Combine

#if os(macOS)
import AppKit
#endif

/// [教程注释：App 入口点]
/// `@main` 标签告诉编译器：这是整个应用程序的绝对入口！
/// 它替代了以前的老古董 `AppDelegate`（尽管我们在下面为了接管特定的 macOS 事件，又手动桥接了它）。
@main
struct SimpleViewApp: App {
    
    // [核心概念：桥接原生生命周期代理]
    // SwiftUI 原生提供的 App 生命周期还比较弱。如果我们需要在 macOS 上拦截窗口关闭、App 退出等底层事件，
    // 就必须通过 `@NSApplicationDelegateAdaptor` 注入我们自己写的 AppDelegate。
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    // [教程注释：环境变量注入]
    // `@Environment` 是一种从系统环境变量中读取依赖的方式。
    // \.openWindow 是 SwiftUI 提供的一个全局闭包，可以随时调用它来打开新的系统窗口。
    @Environment(\.openWindow) private var openWindow
    
    // [核心概念：焦点值绑定]
    // `@FocusedValue` 用于多窗口程序。如果你打开了三个 PDF 窗口，全局菜单栏的按钮怎么知道应该操作哪一个？
    // 答案就是看哪个窗口当前处于“激活(Focused)”状态，它就会动态读取那个窗口的 state。
    @FocusedValue(\.appState) private var focusedState
    @FocusedValue(\.uiState) private var focusedUIState
    
    // 从持久化存储读取当前语言偏好
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    
    @State private var isImporting = false
    
    // 简易多语言翻译函数包
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    
    /// [逻辑流程：App 初始化阶段]
    init() {
        #if os(macOS)
        // 禁用 macOS 原生的“退出时保持窗口恢复”机制。
        // 因为我们自己写了一套极度健壮的状态恢复系统（支持文档持久化定位），
        // 必须把苹果默认的粗暴恢复机制关掉，防止它们打架。
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let useTab = UserDefaults.standard.bool(forKey: "openInTab")
        NSWindow.allowsAutomaticWindowTabbing = useTab
        
        // 启动全局内存压力监听
        _ = MemoryManager.shared
        #endif
    }
    
    // 统一管理快捷键
    @ObservedObject var shortcutManager = ShortcutManager.shared
    
    // [教程注释：全局菜单栏定制]
    // `@CommandsBuilder` 用于重写 Mac 顶部那排原生的系统菜单（文件、编辑、视图等）。
    @CommandsBuilder
    var appCommands: some Commands {
        // [逻辑流程] 替换原生的“新建”菜单组
        CommandGroup(replacing: .newItem) {
            Button(LS("Open...")) {
                #if os(macOS)
                _ = appDelegate.applicationShouldOpenUntitledFile(NSApp)
                #else
                isImporting = true
                #endif
            }.keyboardShortcut(shortcutManager.open.keyEquivalent, modifiers: shortcutManager.open.modifiers)
            
            Button(LS("Find...")) { focusedUIState?.triggerSearchFocus(state: focusedState) }
                .keyboardShortcut(shortcutManager.search.keyEquivalent, modifiers: shortcutManager.search.modifiers)
        }
        
        // 替换“视图 -> 边栏”相关的系统命令
        CommandGroup(replacing: .sidebar) {
            Button(LS("Toggle Left Sidebar")) { focusedUIState?.toggleLeftSidebar(state: focusedState) }
                .keyboardShortcut(shortcutManager.toggleLeftSidebar.keyEquivalent, modifiers: shortcutManager.toggleLeftSidebar.modifiers)
            Button(LS("Toggle Right Sidebar")) { focusedUIState?.toggleRightSidebar(state: focusedState) }
                .keyboardShortcut(shortcutManager.toggleRightSidebar.keyEquivalent, modifiers: shortcutManager.toggleRightSidebar.modifiers)
            
            Divider()
            
            Picker(LS("Switch Language"), selection: $appLanguage) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
        }

        // 替换“编辑 -> 撤销”组，这里我们放标注工具快捷键
        CommandGroup(replacing: .undoRedo) {
            Button(LS("Undo")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalUndo"), object: nil) }
                .keyboardShortcut(shortcutManager.undo.keyEquivalent, modifiers: shortcutManager.undo.modifiers)
            Button(LS("Redo")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalRedo"), object: nil) }
                .keyboardShortcut(shortcutManager.redo.keyEquivalent, modifiers: shortcutManager.redo.modifiers)
            
            Divider()
            
            Button(LS("highlight")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalHighlight"), object: nil) }
                .keyboardShortcut(shortcutManager.highlight.keyEquivalent, modifiers: shortcutManager.highlight.modifiers)
            Button(LS("underline")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalUnderline"), object: nil) }
                .keyboardShortcut(shortcutManager.underline.keyEquivalent, modifiers: shortcutManager.underline.modifiers)
            Button(LS("strikeout")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalStrikeout"), object: nil) }
                .keyboardShortcut(shortcutManager.strikeout.keyEquivalent, modifiers: shortcutManager.strikeout.modifiers)
            Button(LS("none")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalNone"), object: nil) }
                .keyboardShortcut(shortcutManager.none.keyEquivalent, modifiers: shortcutManager.none.modifiers)
        }
        
        // 替换“文件 -> 保存”逻辑
        CommandGroup(replacing: .saveItem) {
            Button(LS("Save")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalSave"), object: nil) }
                .keyboardShortcut(shortcutManager.save.keyEquivalent, modifiers: shortcutManager.save.modifiers)
            #if os(macOS)
            Button(LS("Burn-in Annotations...")) { NotificationCenter.default.post(name: NSNotification.Name("TriggerBurnIn"), object: nil) }
            Button(LS("Close Window")) { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut(shortcutManager.closeWindow.keyEquivalent, modifiers: shortcutManager.closeWindow.modifiers)
            #endif
        }
    }
    
    /// [教程注释：主场景渲染区]
    var body: some Scene {
        #if os(macOS)
        // 在 macOS 上，如果你只提供 `Settings` 场景而不提供 `WindowGroup`，
        // App 启动时将不会自动弹出任何多余的空白主界面！这是极简主义 PDF 阅读器的基石。
        Settings {
            SettingsView()
        }
        .commands { appCommands }
        #else
        // [逻辑流程：iOS 多窗口支持]
        // 苹果在 iOS 14+ 提供了原生的多窗口支持 (通过 WindowGroup)。
        // 这里的 `id` 非常重要，系统用它来追踪和管理同一个应用开启的不同窗口状态。
        WindowGroup(id: "url_viewer", for: URL.self) { $url in
            if let validUrl = url {
                ContentView(url: validUrl)
            } else {
                ContentView(url: nil)
            }
        }
        .commands { appCommands }
        #endif
    }
}
