import SwiftUI

/// AI 的阅读入口独立于正文与状态栏；禁用模块后不创建模型选择或聊天视图。
struct AIAssistantControls: View {
    @ObservedObject var uiState: UIState
    @ObservedObject private var configuration = AIConfigurationStore.shared
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    private func LS(_ key: String) -> String { L.s(key, language) }

    var body: some View {
        HStack(spacing: 12) {
            Picker(LS("AI Model"), selection: Binding(get: { configuration.selectedModelID }, set: { configuration.select($0) })) {
                Text(LS("Select AI Model")).tag(UUID?.none)
                ForEach(configuration.routes) { route in
                    Text(route.label).tag(Optional(route.id))
                }
            }
            .frame(width: 300)
            .labelsHidden()

            Button(action: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    uiState.isAIChatPresented.toggle()
                }
            }) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(uiState.isAIChatPresented ? .white : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(uiState.isAIChatPresented ? Color.blue : Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
    }
}
