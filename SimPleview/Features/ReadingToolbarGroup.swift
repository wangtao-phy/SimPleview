import SwiftUI
import AppKit

/// 可选阅读模块保留原工具栏 ID，已有的工具栏排列仍能恢复。
struct ReadingToolbarGroup: CustomizableToolbarContent {
    @ObservedObject var state: AppState
    @ObservedObject private var features = FeaturePreferences.shared

    var body: some CustomizableToolbarContent {
        if features.pomodoro {
            ToolbarItem(id: "Pomodoro", placement: .primaryAction) {
                FocusTimerButton(documentTitle: state.fileURL?.deletingPathExtension().lastPathComponent,
                                 label: state.L("Pomodoro"))
                    .frame(width: 28, height: 24)
            }
        }

        // 护眼背景色按钮
        if features.eyeCare {
            ToolbarItem(id: "BackgroundColor", placement: .primaryAction) {
                Menu {
                    Button(action: { state.pageBackgroundColor = .default }) {
                        colorMenuText(name: state.L("Default Background"), color: .white)
                    }
                    Button(action: { state.pageBackgroundColor = .green }) {
                        colorMenuText(name: state.L("Eye-care Green"), color: NSColor(red: 0.78, green: 0.93, blue: 0.8, alpha: 1.0))
                    }
                    Button(action: { state.pageBackgroundColor = .yellow }) {
                        colorMenuText(name: state.L("Soft Yellow"), color: NSColor(red: 0.96, green: 0.9, blue: 0.75, alpha: 1.0))
                    }
                    Button(action: { state.pageBackgroundColor = .black }) {
                        colorMenuText(name: state.L("Dark Mode"), color: .black)
                    }
                } label: {
                    Label(state.L("Background Color"), systemImage: "circle.lefthalf.filled")
                }
                .disabled(state.fileURL == nil)
            }
        }
    }

    #if os(macOS)
    private func colorMenuText(name: String, color: NSColor) -> Text {
        // 白色和黑色略向灰色偏移，使菜单色点在两种外观中均可见。
        var displayColor = color
        if color == .white {
            displayColor = NSColor(white: 0.9, alpha: 1.0) // 避免纯白在白底上看不见
        } else if color == .black {
            displayColor = NSColor(white: 0.2, alpha: 1.0)
        }
        var dot = AttributedString("● ")
        dot.foregroundColor = Color(nsColor: displayColor)

        let text = AttributedString(name)
        return Text(dot + text)
    }
    #endif
}
