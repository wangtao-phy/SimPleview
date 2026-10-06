import SwiftUI

/// 仿系统设置的类别侧栏，右侧只展示当前类别。搜索范围为该类别，配置保持不变。
struct ShortcutsSettingsView: View {
    @ObservedObject private var manager = ShortcutManager.shared
    @ObservedObject private var features = FeaturePreferences.shared
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @AppStorage("enableTodo") private var enableTodo = true
    @AppStorage("enableReadingRecord") private var enableRecord = false
    @State private var query = ""
    @State private var selectedGroup: ShortcutGroup = .file
    private func text(_ key: String) -> String { L.s(key, language) }

    private func actions(in group: ShortcutGroup) -> [ShortcutAction] {
        ShortcutAction.allCases.filter {
            $0.definition.group == group && (query.isEmpty || text($0.definition.title).localizedCaseInsensitiveContains(query)
                || manager[$0].displayString.localizedCaseInsensitiveContains(query))
        }
    }

    private func available(_ action: ShortcutAction) -> Bool {
        switch action {
        case .windowManagement: return features.windowManagement
        case .pomodoro: return features.pomodoro
        case .eyeCare: return features.eyeCare
        case .todo: return enableTodo
        case .history: return enableRecord
        default: return true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedGroup) {
                ForEach(ShortcutGroup.allCases, id: \.self) { group in
                    Label(text(group.rawValue), systemImage: icon(for: group)).tag(group)
                        .font(.title3)
                        .padding(.vertical, 6)
                }
            }.listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(width: 185)
                // 保留系统圆角选中样式；背景与材质只在当前标签页内显示。
                .background(Color(nsColor: .controlBackgroundColor))
                .clipped()
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(text("Search Shortcuts"), text: $query).textFieldStyle(.plain)
                        .accessibilityLabel(text("Search Shortcuts"))
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(16)
                Divider()
                Form {
                    let matches = actions(in: selectedGroup)
                    if !matches.isEmpty {
                        Section(text(selectedGroup.rawValue)) {
                            ForEach(matches) { action in
                                HStack {
                                    Text(text(action.definition.title))
                                        .foregroundStyle(available(action) ? Color.primary : Color.secondary)
                                    Spacer(minLength: 24)
                                    ShortcutRecorderView(shortcut: manager.binding(for: action), validate: {
                                        manager.validationMessage(for: $0, replacing: action, language: language)
                                    }, onSave: { manager.saveToDefaults() })
                                    .accessibilityLabel(text(action.definition.title))
                                }
                            }
                        }
                    }
                    if query.isEmpty && selectedGroup == .navigation {
                        Section(text("Standard Sidebar Shortcuts")) {
                            LabeledContent(text("Select All Pages"), value: "⌘A")
                            LabeledContent(text("Copy Pages"), value: "⌘C")
                            LabeledContent(text("Paste Pages After"), value: "⌘V")
                            LabeledContent(text("Select Page Range"), value: "⇧ + ↑ / ↓")
                            LabeledContent(text("Delete Selected Pages"), value: "⌫")
                            Text(text("Sidebar Shortcut Help")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !query.isEmpty, matches.isEmpty {
                        Text(text("No Matching Shortcuts")).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                Divider()
                HStack {
                    Text(text("Shortcut Recording Help")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(text("Restore Defaults")) { manager.resetToDefaults() }
                }.padding(16)
            }
        }
    }

    private func icon(for group: ShortcutGroup) -> String {
        switch group {
        case .file: "doc"
        case .navigation: "sidebar.left"
        case .annotation: "highlighter"
        case .reading: "book"
        }
    }
}
