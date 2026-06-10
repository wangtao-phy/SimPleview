import SwiftUI
import UniformTypeIdentifiers

/// [教程注释：外部浏览器大全配置]
/// 这是一个标准的枚举 (Enum)，穷举了世面上你能见到的所有主流浏览器。
/// 为什么要把它写死？因为 Mac 上的应用程序之间跳转需要知道确切的 Bundle ID，
/// 这就像是每个 App 在系统内部注册的身份证号一样。
enum ExternalBrowser: String, CaseIterable, Identifiable {
    case defaultBrowser = "Default"
    case safari = "Safari"
    case edge = "Edge"
    case chrome = "Chrome"
    case orion = "Orion"
    case tabbit = "Tabbit"
    case other = "Other"
    
    var id: String { rawValue } // 必须遵守 Identifiable 协议，才能被 SwiftUI 的 ForEach 遍历成菜单选项
    
    // 给人类看的展示文字
    var displayName: String {
        switch self {
        case .defaultBrowser: return "Default Browser"
        case .safari: return "Safari"
        case .edge: return "Edge"
        case .chrome: return "Chrome"
        case .orion: return "Orion"
        case .tabbit: return "Tabbit"
        case .other: return "Other Application..."
        }
    }
    
    // [黑科技：App 身份证号大全]
    // 这是用来告诉系统级方法 "NSWorkspace.shared.open" 到底该用哪个程序强行打开 URL
    var bundleIdentifiers: [String] {
        switch self {
        case .defaultBrowser, .other: return []
        // 有些浏览器（如 Safari）有多个变种版本（比如测试版和稳定版），所以存成一个数组，挨个去碰运气
        case .safari: return ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
        case .edge: return ["com.microsoft.edgemac"]
        case .chrome: return ["com.google.Chrome"]
        case .orion: return ["com.kagi.kagimacOS"]
        // Tabbit 这个浏览器由于非常小众，改过好几次包名，所以这里罗列了一大堆它可能的身份证号
        case .tabbit: return ["com.tabbit.Tabbit", "app.tabbit.mac", "com.sindresorhus.Tabbit", "com.sindresorhus.Tabbit-macOS", "com.ruan.Tabbit"]
        }
    }
    
    // 这是给如果身份证号没找到时留的后门备用方案：告诉系统，通过它的应用程序官方名称去搜索
    var appName: String? {
        switch self {
        case .defaultBrowser, .other: return nil
        case .safari: return "Safari"
        case .edge: return "Microsoft Edge"
        case .chrome: return "Google Chrome"
        case .orion: return "Orion"
        case .tabbit: return "Tabbit"
        }
    }
}

/// [教程注释：总设置窗口壳子 (SettingsView)]
/// 这是整个设置菜单的主框架。
/// 它自身其实没有任何内容，全靠 TabView 这个壳子把我们拆分出去的四个具体的设置面板组装在一起。
struct SettingsView: View {
    // 为什么要在这里再声明一次？因为如果用户在通用里关了“阅读记录”，我们要动态把它的那一页给置灰隐藏掉。
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    @AppStorage("hibernationTimeoutStr") var hibernationTimeoutStr: String = "20"
    @AppStorage("openInTab") var openInTab: Bool = false
    @AppStorage("externalBrowser") var externalBrowser: ExternalBrowser = .defaultBrowser
    @AppStorage("customBrowserPath") var customBrowserPath: String = ""
    @AppStorage("enableReadingRecord") var enableReadingRecord: Bool = false
    
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    
    var body: some View {
        // TabView：macOS 上的带多个标签页的窗口控制器
        TabView {
            // MARK: - General Tab (第一页：通用)
            GeneralSettingsView(LS: LS)
                .tabItem { // 这个 tabItem 就是挂在窗户最顶上的那个小按钮和文字
                    Label(LS("General"), systemImage: "gearshape")
                }

            
            // MARK: - Shortcuts Tab (第二页：快捷键)
            ShortcutsSettingsView()
                .tabItem {
                    Label(LS("Shortcuts"), systemImage: "keyboard")
                }
            
            // MARK: - Annotation Tab (第三页：批注)
            AnnotationSettingsView()
                .tabItem {
                    Label(LS("Annotation"), systemImage: "highlighter")
                }
            
            // MARK: - Record Tab (第四页：记录)
            RecordSettingsView()
                .tabItem {
                    Label(LS("Record"), systemImage: "clock.arrow.circlepath")
                }
                // [动态权限锁]
                // disabled 属性，如果我们发现通用设置里那根总开关关了，这一页的所有按钮都会变成灰色点不动！
                .disabled(!enableReadingRecord)
        }
        // [窗口刚性限制]
        // 设置菜单不同于阅读页面，它的内容是不变的，所以给它定死了一个最小框，防止用户把它缩成一团导致排版崩坏。
        .frame(minWidth: 500, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        #if os(macOS)
        // [底层窗口配置渗透]
        // 监听 "在标签页中打开" 设置，如果变化，直接深入 Mac 系统核心去篡改 NSWindow 的全局属性。
        .onChange(of: openInTab) { _, newValue in
            NSWindow.allowsAutomaticWindowTabbing = newValue
        }
        #endif
    }
}
