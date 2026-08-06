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
        if useTab {
            UserDefaults.standard.set(true, forKey: "AppleWindowTabbingMode")
        }
        
        UpdateManager.shared.startMonitoring()
        
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
        CommandGroup(after: .appSettings) {
            Button(LS("Check for Updates...")) {
                UpdateManager.shared.checkForUpdates(manual: true)
            }
        }
        
        CommandGroup(replacing: .newItem) {
            #if os(macOS)
            Button(LS("New Blank File...")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalNewDocument"), object: nil) }
                .keyboardShortcut(shortcutManager.newDocument.keyEquivalent, modifiers: shortcutManager.newDocument.modifiers)
            #endif
            
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
            
            Button(LS("Compare View")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalCompareView"), object: nil) }
                .keyboardShortcut(shortcutManager.compareView.keyEquivalent, modifiers: shortcutManager.compareView.modifiers)
            
            Button(LS("Slideshow")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalPresentation"), object: nil) }
                .keyboardShortcut(shortcutManager.slideshow.keyEquivalent, modifiers: shortcutManager.slideshow.modifiers)
            
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
            Button(LS("Draw")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalInk"), object: nil) }
                .keyboardShortcut(shortcutManager.ink.keyEquivalent, modifiers: shortcutManager.ink.modifiers)
        }
        
        // 替换“文件 -> 保存”逻辑
        CommandGroup(replacing: .saveItem) {
            Button(LS("Save")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalSave"), object: nil) }
                .keyboardShortcut(shortcutManager.save.keyEquivalent, modifiers: shortcutManager.save.modifiers)
            #if os(macOS)
            Button(LS("Reveal in Finder")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalRevealInFinder"), object: nil) }
                .keyboardShortcut(shortcutManager.revealInFinder.keyEquivalent, modifiers: shortcutManager.revealInFinder.modifiers)
            
            Button(LS("Burn-in Annotations...")) { NotificationCenter.default.post(name: NSNotification.Name("TriggerBurnIn"), object: nil) }
                .keyboardShortcut(shortcutManager.burnIn.keyEquivalent, modifiers: shortcutManager.burnIn.modifiers)
            
            Button(LS("Close Window")) { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut(shortcutManager.closeWindow.keyEquivalent, modifiers: shortcutManager.closeWindow.modifiers)
            #endif
        }
        
        // 增加系统的打印功能
        CommandGroup(replacing: .printItem) {
            #if os(macOS)
            Button(LS("Print...")) { NotificationCenter.default.post(name: NSNotification.Name("GlobalPrint"), object: nil) }
                .keyboardShortcut("p", modifiers: .command)
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

class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @AppStorage("autoCheckUpdates") var autoCheckUpdates: Bool = true
    
    private var midnightTimer: Timer?
    
    private init() {
    }
    
    func startMonitoring() {
        if autoCheckUpdates {
            checkForUpdates(manual: false)
        }
        scheduleMidnightCheck()
    }
    
    private func scheduleMidnightCheck() {
        midnightTimer?.invalidate()
        
        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.day? += 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        
        guard let midnight = Calendar.current.date(from: components) else { return }
        let timeInterval = midnight.timeIntervalSince(now)
        
        midnightTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.autoCheckUpdates {
                self.checkForUpdates(manual: false)
            }
            self.scheduleMidnightCheck()
        }
    }
    
    func checkForUpdates(manual: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/wangtao-phy/SimPleview/releases/latest") else { return }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil else {
                    if manual {
                        self.showNetworkError()
                    }
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let tagName = json["tag_name"] as? String,
                       let htmlUrlStr = json["html_url"] as? String,
                       let htmlUrl = URL(string: htmlUrlStr) {
                        
                        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                        
                        let cleanTag = tagName.replacingOccurrences(of: "v", with: "")
                        let cleanCurrent = currentVersion.replacingOccurrences(of: "v", with: "")
                        
                        if cleanTag.compare(cleanCurrent, options: .numeric) == .orderedDescending {
                            self.showUpdateAvailableAlert(newVersion: tagName, url: htmlUrl)
                        } else {
                            if manual {
                                self.showUpToDateAlert()
                            }
                        }
                    } else {
                        if manual {
                            self.showNetworkError()
                        }
                    }
                } catch {
                    if manual {
                        self.showNetworkError()
                    }
                }
            }
        }
        task.resume()
    }
    
    private func getLS(_ key: String) -> String {
        let langStr = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh"
        let lang: AppLanguage = langStr == "en" ? .en : .zh
        return SimPleview.L.s(key, lang)
    }
    
    #if os(macOS)
    private func showUpdateAvailableAlert(newVersion: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = getLS("Update Available")
        alert.informativeText = getLS("A new version is available!") + " (\(newVersion))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: getLS("Download"))
        alert.addButton(withTitle: getLS("Cancel"))
        
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = getLS("Up to date")
        alert.informativeText = getLS("You are using the latest version of SimPleview.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: getLS("OK"))
        alert.runModal()
    }
    
    private func showNetworkError() {
        let alert = NSAlert()
        alert.messageText = getLS("Network error while checking for updates.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: getLS("OK"))
        alert.runModal()
    }
    #endif
}
