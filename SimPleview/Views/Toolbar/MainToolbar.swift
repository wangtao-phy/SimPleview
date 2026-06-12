import SwiftUI

/// 统一聚合整个 App 的主工具栏
struct MainToolbar: ViewModifier {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    let pageNumberInput: AnyView
    
    func body(content: Content) -> some View {
        content
            .toolbar(id: "MainToolbar") {
                NavigationToolbarGroup(state: state, pageNumberInput: pageNumberInput)
                AnnotationToolbarGroup(state: state)
                DocumentToolbarGroup(state: state, uiState: uiState)
            }
            .toolbarRole(.editor)
    }
}

extension View {
    func mainToolbar(state: AppState, uiState: UIState, pageNumberInput: AnyView) -> some View {
        self.modifier(MainToolbar(state: state, uiState: uiState, pageNumberInput: pageNumberInput))
    }
}
