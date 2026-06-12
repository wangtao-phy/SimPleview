import SwiftUI

/// 专门负责文档全局操作的工具栏组件（包括旋转、对比、浏览器打开、幻灯片、侧边栏切换等）
struct DocumentToolbarGroup: CustomizableToolbarContent {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "RotateLeft", placement: .primaryAction) {
            Button(action: { state.rotateCurrentPageLeft() }) { 
                Label(state.L("Rotate Left"), systemImage: "rotate.left") 
            }
            .disabled(state.fileURL == nil)
        }
        
        ToolbarItem(id: "Compare", placement: .primaryAction) {
            Button(action: { state.openCompareWindow() }) { 
                Label(state.L("Comparison"), systemImage: "document.on.document") 
            }
            .disabled(state.fileURL == nil)
        }
        
        ToolbarItem(id: "Browser", placement: .primaryAction) {
            Button(action: { state.openInBrowser() }) { 
                Label(state.L("Browser"), systemImage: "safari") 
            }
            .disabled(state.fileURL == nil)
        }
        
        ToolbarItem(id: "Slideshow", placement: .primaryAction) {
            Button(action: { uiState.isSlideshowActive.toggle() }) { 
                Label(uiState.isSlideshowActive ? state.L("Exit Slideshow") : state.L("Enter Slideshow"), systemImage: uiState.isSlideshowActive ? "pause.circle.fill" : "play.circle") 
            }
            .disabled(state.fileURL == nil)
        }
        
        ToolbarItem(id: "Finder", placement: .primaryAction) {
            Button(action: { state.revealInFinder() }) { 
                Label(state.L("Finder"), systemImage: "folder") 
            }
            .disabled(state.fileURL == nil)
        }
        
        ToolbarItem(id: "RightSidebar", placement: .primaryAction) {
            Button(action: { uiState.toggleRightSidebar(state: state) }) {
                Label(state.L("Right Column"), systemImage: "sidebar.right")
                    .symbolVariant(uiState.showRightSidebar ? .fill : .none)
            }
            .disabled(state.fileURL == nil)
        }
    }
}
