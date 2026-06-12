import SwiftUI

/// 专门负责导航控制的工具栏组件（包括后退、页码输入跳转）
struct NavigationToolbarGroup: CustomizableToolbarContent {
    @ObservedObject var state: AppState
    let pageNumberInput: AnyView
    
    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "Navigation", placement: .navigation) {
            HStack(spacing: 4) {
                Button(action: { state.goBack() }) { 
                    Image(systemName: "chevron.left.circle") 
                }
                .disabled(state.navigationHistory.isEmpty)
                
                pageNumberInput.disabled(state.fileURL == nil)
            }
        }
    }
}
