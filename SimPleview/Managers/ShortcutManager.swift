import SwiftUI
import Combine

/// [教程注释：快捷键底层数据结构]
/// 这个结构体用来定义一个快捷键的长相。比如 `Cmd + S` 或者 `Ctrl + ⌥ + P`。
/// 因为要把它存在本地硬盘上持久化，所以必须要实现 `Codable` 协议。
struct AppShortcut: Codable, Equatable {
    /// 按的是哪个字母（比如 "s"）
    var key: String
    /// 修饰键（Cmd, Shift, Ctrl 等）的底层按位或(Bitwise OR)整数形式
    var modifiersRawValue: Int
    
    // 把我们的字符串转换成 SwiftUI 原生的 KeyEquivalent 格式
    var keyEquivalent: KeyEquivalent {
        guard let first = key.first else { return KeyEquivalent(" ") }
        return KeyEquivalent(first)
    }
    
    // 把数字转换成 SwiftUI 原生的修饰键枚举
    var modifiers: EventModifiers {
        EventModifiers(rawValue: modifiersRawValue)
    }
    
    init(key: Character, modifiers: EventModifiers) {
        self.key = String(key)
        self.modifiersRawValue = modifiers.rawValue
    }
    
    // [UI 展示：把快捷键翻译成人类能看懂的符号]
    // 比如把修饰键变成 ⌘, ⌥, ⇧ 这种只有苹果系统才有的神仙符号。
    var displayString: String {
        var str = ""
        let mods = self.modifiers
        if mods.contains(.control) { str += "⌃" }
        if mods.contains(.option) { str += "⌥" }
        if mods.contains(.shift) { str += "⇧" }
        if mods.contains(.command) { str += "⌘" }
        
        let displayKey = key.uppercased()
        switch displayKey {
        case "\r": str += "↩"
        case "\t": str += "⇥"
        case " ": str += "Space"
        case "\u{1B}": str += "⎋" // Escape
        default: str += displayKey
        }
        return str
    }
}

/// [教程注释：全局快捷键总管]
/// 负责存放、加载和保存目前 App 支持的所有可自定义快捷键。
/// 也是一个单例，因为快捷键配置在整个 App 里只有唯一一份。
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()
    
    // 下面所有的属性都加了 @Published。
    // 这意味着：如果在设置中心修改了某个快捷键，顶部系统菜单栏 (Menu Bar) 会瞬间自动更新！不需要写一行通知代码。
    @Published var open = AppShortcut(key: "o", modifiers: .command)
    @Published var search = AppShortcut(key: "f", modifiers: .command)
    @Published var toggleLeftSidebar = AppShortcut(key: "[", modifiers: .control)
    @Published var toggleRightSidebar = AppShortcut(key: "]", modifiers: .control)
    @Published var undo = AppShortcut(key: "z", modifiers: .command)
    @Published var redo = AppShortcut(key: "z", modifiers: [.command, .shift])
    
    // 工具快捷键
    @Published var highlight = AppShortcut(key: "i", modifiers: .control)
    @Published var underline = AppShortcut(key: "o", modifiers: .control)
    @Published var strikeout = AppShortcut(key: "p", modifiers: .control)
    @Published var none = AppShortcut(key: "u", modifiers: .control)
    
    @Published var save = AppShortcut(key: "s", modifiers: .command)
    @Published var closeWindow = AppShortcut(key: "w", modifiers: .command)
    @Published var openInBrowser = AppShortcut(key: "g", modifiers: .command)
    
    // 保存在 UserDefaults 里的一大坨 JSON 的 Key 名称
    private let userDefaultsKey = "AppShortcutsConfig"
    
    private init() {
        // App 启动时自动去偏好设置里捞数据
        load()
    }
    
    // [加载配置]
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        do {
            let dict = try JSONDecoder().decode([String: AppShortcut].self, from: data)
            // 解析出来后，逐个覆盖默认值
            if let v = dict["open"] { open = v }
            if let v = dict["search"] { search = v }
            if let v = dict["toggleLeftSidebar"] { toggleLeftSidebar = v }
            if let v = dict["toggleRightSidebar"] { toggleRightSidebar = v }
            if let v = dict["undo"] { undo = v }
            if let v = dict["redo"] { redo = v }
            if let v = dict["highlight"] { highlight = v }
            if let v = dict["underline"] { underline = v }
            if let v = dict["strikeout"] { strikeout = v }
            if let v = dict["none"] { none = v }
            if let v = dict["save"] { save = v }
            if let v = dict["closeWindow"] { closeWindow = v }
            if let v = dict["openInBrowser"] { openInBrowser = v }
        } catch {
            // Ignore
        }
    }
    
    // [保存配置]
    func saveToDefaults() {
        // 打包成一个大字典
        let dict: [String: AppShortcut] = [
            "open": open,
            "search": search,
            "toggleLeftSidebar": toggleLeftSidebar,
            "toggleRightSidebar": toggleRightSidebar,
            "undo": undo,
            "redo": redo,
            "highlight": highlight,
            "underline": underline,
            "strikeout": strikeout,
            "none": none,
            "save": save,
            "closeWindow": closeWindow,
            "openInBrowser": openInBrowser
        ]
        
        do {
            // 将字典编码成 JSON，塞入操作系统的 UserDefaults 数据库中
            let data = try JSONEncoder().encode(dict)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            // Ignore
        }
    }
    
    // [一键还原默认设置]
    func resetToDefaults() {
        open = AppShortcut(key: "o", modifiers: .command)
        search = AppShortcut(key: "f", modifiers: .command)
        toggleLeftSidebar = AppShortcut(key: "[", modifiers: .control)
        toggleRightSidebar = AppShortcut(key: "]", modifiers: .control)
        undo = AppShortcut(key: "z", modifiers: .command)
        redo = AppShortcut(key: "z", modifiers: [.command, .shift])
        highlight = AppShortcut(key: "i", modifiers: .control)
        underline = AppShortcut(key: "o", modifiers: .control)
        strikeout = AppShortcut(key: "p", modifiers: .control)
        none = AppShortcut(key: "u", modifiers: .control)
        save = AppShortcut(key: "s", modifiers: .command)
        closeWindow = AppShortcut(key: "w", modifiers: .command)
        openInBrowser = AppShortcut(key: "g", modifiers: .command)
        saveToDefaults() // 别忘了最后执行存盘
    }
}
