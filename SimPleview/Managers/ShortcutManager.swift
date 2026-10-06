import SwiftUI
import Combine

@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()
    private let defaults: UserDefaults
    private let storageKey = "AppShortcutsConfig"
    @Published private var shortcuts: [String: AppShortcut]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 继续使用旧字典的键名；新动作缺省时使用默认值，旧自定义组合不被覆盖。
        var restored = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: AppShortcut].self, from: $0) } ?? [:]
        // 旧自定义组合优先。新增动作若与它冲突，暂不绑定，留给用户选择。
        for action in ShortcutAction.allCases where restored[action.rawValue] == nil {
            let candidate = action.defaultShortcut
            let occupied = restored.values.contains {
                $0.key.lowercased() == candidate.key.lowercased() && $0.modifiers == candidate.modifiers
            }
            if occupied {
                var unassigned = candidate
                unassigned.key = ""
                restored[action.rawValue] = unassigned
            } else {
                restored[action.rawValue] = candidate
            }
        }
        shortcuts = restored
    }

    subscript(action: ShortcutAction) -> AppShortcut {
        get { shortcuts[action.rawValue] ?? action.defaultShortcut }
        set { shortcuts[action.rawValue] = newValue }
    }

    func binding(for action: ShortcutAction) -> Binding<AppShortcut> {
        Binding(get: { self[action] }, set: { self[action] = $0 })
    }

    func validationMessage(for candidate: AppShortcut, replacing action: ShortcutAction, language: AppLanguage) -> String? {
        guard !candidate.modifiers.intersection([.command, .control, .option]).isEmpty else {
            return L.s("Shortcut Modifier Required", language)
        }
        // 文本编辑、缩略图多选与系统设置的标准组合保持可用。
        if candidate.modifiers == .command, ["a", "c", "v", "x", ",", "q", "h", "m", "`"].contains(candidate.key.lowercased()) {
            return L.s("Shortcut Reserved", language)
        }
        if (candidate.modifiers == [.command, .option] && candidate.key.lowercased() == "h")
            || (candidate.modifiers == [.command, .control] && candidate.key.lowercased() == "f") {
            return L.s("Shortcut Reserved", language)
        }
        if let other = ShortcutAction.allCases.first(where: {
            $0 != action && self[$0].key.lowercased() == candidate.key.lowercased() && self[$0].modifiers == candidate.modifiers
        }) {
            return String(format: L.s("Shortcut Used By", language), L.s(other.definition.title, language))
        }
        return nil
    }

    func saveToDefaults() {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        defaults.set(data, forKey: storageKey)
    }

    func resetToDefaults() {
        shortcuts = [:]
        saveToDefaults()
    }
}
