import SwiftUI
import UniformTypeIdentifiers

/// 已知浏览器优先按 Bundle ID 查找，找不到时用应用名称；其他应用由用户选择。
enum ExternalBrowser: String, CaseIterable, Identifiable {
    case defaultBrowser = "Default"
    case safari = "Safari"
    case edge = "Edge"
    case chrome = "Chrome"
    case orion = "Orion"
    case tabbit = "Tabbit"
    case other = "Other"
    
    var id: String { rawValue }
    
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
    
    var bundleIdentifiers: [String] {
        switch self {
        case .defaultBrowser, .other: return []
        case .safari: return ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
        case .edge: return ["com.microsoft.edgemac"]
        case .chrome: return ["com.google.Chrome"]
        case .orion: return ["com.kagi.kagimacOS"]
        case .tabbit: return ["com.tabbit.Tabbit", "app.tabbit.mac", "com.sindresorhus.Tabbit", "com.sindresorhus.Tabbit-macOS", "com.ruan.Tabbit"]
        }
    }
    
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

/// 设置只负责组织页面；各页独立管理对应模块的偏好。
struct SettingsView: View {
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    private func text(_ key: String) -> String { L.s(key, language) }

    var body: some View {
        TabView {
            GeneralSettingsView(LS: text)
                .frame(maxWidth: 580).frame(maxWidth: .infinity)
                .tabItem { Label(text("General"), systemImage: "gearshape") }
            FileSettingsView()
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
                .tabItem { Label(text("Files"), systemImage: "doc") }
            ReadingSettingsView()
                .frame(maxWidth: 580).frame(maxWidth: .infinity)
                .tabItem { Label(text("Reading"), systemImage: "highlighter") }
            VStack(spacing: 0) {
                Divider()
                ShortcutsSettingsView()
            }
                .tabItem { Label(text("Shortcuts"), systemImage: "keyboard") }
            SettingsAIView()
                .frame(maxWidth: 620).frame(maxWidth: .infinity)
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: .infinity,
               minHeight: 560, idealHeight: 780, maxHeight: .infinity)
    }
}
