import SwiftUI

/// 专门负责导航控制的工具栏组件（包括后退、页码输入跳转）
struct NavigationToolbarGroup: CustomizableToolbarContent {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    let pageNumberInput: AnyView
    
    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "Navigation", placement: .navigation) {
            HStack(spacing: 4) {
                // 标签页分组按钮 (Tab Groups Popover)
                #if os(macOS)
                Button(action: { uiState.isShowingTabGroupsPopover.toggle() }) {
                    Image(systemName: "square.grid.2x2")
                }
                .popover(isPresented: $uiState.isShowingTabGroupsPopover, arrowEdge: .bottom) {
                    TabGroupsPopoverView()
                }
                #endif
                
                Button(action: { state.goBack() }) { 
                    Image(systemName: "chevron.left.circle") 
                }
                .disabled(state.navigationHistory.isEmpty)
                
                pageNumberInput.disabled(state.fileURL == nil)
            }
        }
    }
}
