import Foundation
import Combine
import PDFKit

/// 剥离出的核心实时视图状态，由 Swift 6 `@Observable` 驱动。
///
/// 由于其不依赖 `ObservableObject` 及其自带的 `@Published`（即任意属性变动都会强制整个环境内的视图树刷新），
/// 所以这部分包含了原本最容易导致掉帧的“极高频状态”：
/// - `currentPageIndex`：用户滚动页面时，一秒内可触发几十次。
/// - 拖放及选取相关指标。
///
/// 通过将这些属性隔离在此，只有显式使用了对应属性（例如 `state.liveState.currentPageIndex`）的叶子视图才会被重绘，
/// 从而实现了 SwiftUI 在庞大应用场景下精准属性级刷新的性能飞跃。
@Observable
@MainActor
final class AppLiveState {
    
    // MARK: - Combine 桥接
    
    /// 由于迁移到 @Observable 后，自动失去 `$currentPageIndex` 这个 Publisher，
    /// 为了兼容原有的 `debounce` (防抖) 与存储持久化等业务，我们在此手动重建发布通道。
    @ObservationIgnored
    let pageIndexSubject = PassthroughSubject<Int, Never>()
    
    // MARK: - 剥离的高频属性
    
    var currentPageIndex: Int = 0 {
        didSet {
            pageIndexSubject.send(currentPageIndex)
        }
    }
    
    var totalPageCount: Int = 0
    
    // 拖放交互：极高频变动
    var dropTargetIndex: Int? = nil
    var draggedIndices: Set<Int>? = nil
    
    // 选中的目录节点
    var selectedOutline: PDFOutline?
}
