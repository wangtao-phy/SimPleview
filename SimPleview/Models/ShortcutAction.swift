import SwiftUI

/// 保留旧版 JSON 的字符和修饰键字段，配置可以直接升级。
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

    var keyboardShortcut: KeyboardShortcut? {
        key.isEmpty ? nil : KeyboardShortcut(keyEquivalent, modifiers: modifiers)
    }

    // 空组合用于升级时避让已被用户占用的快捷键。
    var displayString: String {
        guard !key.isEmpty else { return "—" }
        var str = ""
        let mods = self.modifiers
        if mods.contains(.control) { str += "⌃" }
        if mods.contains(.option) { str += "⌥" }
        if mods.contains(.shift) { str += "⇧" }
        if mods.contains(.command) { str += "⌘" }

        let displayKey = key.uppercased()
        switch displayKey {
        case String(KeyEquivalent.upArrow.character): str += "↑"
        case String(KeyEquivalent.downArrow.character): str += "↓"
        case "\r": str += "↩"
        case "\t": str += "⇥"
        case " ": str += "Space"
        case "\u{1B}": str += "⎋" // Escape
        default: str += displayKey
        }
        return str
    }
}

/// 动作、默认组合和设置分组共用一份目录，避免菜单已有功能却漏列在设置页。
enum ShortcutGroup: String, CaseIterable {
    case file = "File Operations", navigation = "Navigation", annotation = "Annotations", reading = "Reading Tools"
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case undo, redo
    case open, newDocument, save, closeWindow, revealInFinder, burnIn, printDocument
    case search, toggleLeftSidebar, toggleRightSidebar, compareView, slideshow, goBack, previousPage, nextPage
    case zoomIn, zoomOut, actualSize, fitPage, rotateLeft, rotateRight
    case highlight, underline, strikeout, none, ink, signature, toggleAnnotations
    case history, openInBrowser, toggleAIChat, windowManagement, pomodoro, eyeCare, todo, authors
    var id: String { rawValue }

    var definition: (title: String, group: ShortcutGroup, key: Character, modifiers: EventModifiers) {
        switch self {
        case .undo: return ("Undo", .file, "z", .command)
        case .redo: return ("Redo", .file, "z", [.command, .shift])
        case .open: return ("Open File", .file, "o", .command)
        case .newDocument: return ("New Blank File...", .file, "n", [.command, .shift])
        case .save: return ("Save", .file, "s", .command)
        case .closeWindow: return ("Close Window", .file, "w", .command)
        case .revealInFinder: return ("Reveal in Finder", .file, "o", [.command, .shift])
        case .burnIn: return ("Export PDF...", .file, "s", [.command, .shift])
        case .printDocument: return ("Print...", .file, "p", .command)
        case .search: return ("Find...", .navigation, "f", .command)
        case .toggleLeftSidebar: return ("Toggle Left Sidebar", .navigation, "[", .control)
        case .toggleRightSidebar: return ("Toggle Right Sidebar", .navigation, "]", .control)
        case .compareView: return ("Compare View", .navigation, "c", .control)
        case .slideshow: return ("Slideshow", .navigation, "f", .control)
        case .goBack: return ("Go Back", .navigation, "[", .command)
        case .previousPage: return ("Previous Page", .navigation, KeyEquivalent.upArrow.character, [.command, .option])
        case .nextPage: return ("Next Page", .navigation, KeyEquivalent.downArrow.character, [.command, .option])
        case .zoomIn: return ("Zoom In", .navigation, "+", .command)
        case .zoomOut: return ("Zoom Out", .navigation, "-", .command)
        case .actualSize: return ("Actual Size", .navigation, "0", .command)
        case .fitPage: return ("Fit Page", .navigation, "9", .command)
        case .rotateLeft: return ("Rotate Left", .navigation, "l", .command)
        case .rotateRight: return ("Rotate Right", .navigation, "l", [.command, .shift])
        case .highlight: return ("highlight", .annotation, "i", .control)
        case .underline: return ("underline", .annotation, "o", .control)
        case .strikeout: return ("strikeout", .annotation, "p", .control)
        case .none: return ("none", .annotation, "u", .control)
        case .ink: return ("Draw", .annotation, "h", .control)
        case .signature: return ("Signature", .annotation, "s", .control)
        case .toggleAnnotations: return ("Toggle Annotations", .annotation, "h", [.command, .shift])
        case .history: return ("History", .reading, "y", .command)
        case .openInBrowser: return ("Open in Browser", .reading, "g", .command)
        case .toggleAIChat: return ("Toggle AI Assistant", .reading, "'", .control)
        case .windowManagement: return ("Window Management", .reading, "g", .control)
        case .pomodoro: return ("Pomodoro", .reading, "t", .control)
        case .eyeCare: return ("Background Color", .reading, "b", .control)
        case .todo: return ("Todo", .reading, "d", .control)
        case .authors: return ("Global Authors Library", .reading, "a", [.command, .option])
        }
    }
    var defaultShortcut: AppShortcut { AppShortcut(key: definition.key, modifiers: definition.modifiers) }
}
