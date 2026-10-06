import SwiftUI

/// 窗口管理的入口独立于缩略图；关闭模块时同时关闭其弹出框。
struct WindowManagementButton: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    @ObservedObject private var features = FeaturePreferences.shared

    var body: some View {
        Group {
            if features.windowManagement {
                Button { uiState.isShowingTabGroupsPopover.toggle() } label: {
                    Image(systemName: "square.grid.2x2").foregroundStyle(.primary)
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help(state.L("Window Management"))
                .popover(isPresented: $uiState.isShowingTabGroupsPopover, arrowEdge: .bottom) {
                    TabGroupsPopoverView()
                }
            }
        }
        .onChange(of: features.windowManagement) { _, enabled in
            if !enabled { uiState.isShowingTabGroupsPopover = false }
        }
    }
}
