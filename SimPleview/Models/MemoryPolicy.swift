import Foundation
import PDFKit

/// 内存与性能管理策略协议
/// 用于彻底解耦 `MemoryMode` 与具体 UI 视图的依赖，将所有的配置参数抽象化。
protocol MemoryPolicy {
    // MARK: - 渲染级策略
    /// PDF 插值质量（清晰度 vs 速度）
    var interpolationQuality: PDFInterpolationQuality { get }
    /// 是否开启高级页面阴影
    var pageShadowsEnabled: Bool { get }
    
    // MARK: - 缓存级策略
    /// 缩略图最大生成边长
    var thumbnailMaxEdge: CGFloat { get }
    
    // MARK: - 交互级策略
    /// 侧边栏极速滚动时，是否为了防抖而延迟跳转（防渲染风暴）
    var delaysNavigationJumps: Bool { get }
    
    // MARK: - 休眠级策略
    /// 文档关闭时，是否要激进地清空整个 Thumbnail 缓存？
    var aggressivePurgeOnClose: Bool { get }
    /// 是否允许休眠
    var allowsHibernation: Bool { get }
}

/// 性能模式：对标 macOS Preview.app
/// 较高渲染质量和直接跳转；缩略图仍受全应用字节预算约束。
struct PerformanceMemoryPolicy: MemoryPolicy {
    var interpolationQuality: PDFInterpolationQuality { .high }
    var pageShadowsEnabled: Bool { true }
    
    // 最终像素边长。缓存容量由 ThumbnailStore 统一按字节计费。
    var thumbnailMaxEdge: CGFloat { 640 }
    
    var delaysNavigationJumps: Bool { false }
    
    var aggressivePurgeOnClose: Bool { true } // 关闭后释放该窗口缓存
    var allowsHibernation: Bool { false }
}

/// 节约模式：对标 Skim
/// 降级渲染质量、极小的内存上限、遇到压力或关闭文档立即回收、极速滚动开启防抖。
struct SavingMemoryPolicy: MemoryPolicy {
    var interpolationQuality: PDFInterpolationQuality { .none } // 追求最低内存占用和最快渲染
    var pageShadowsEnabled: Bool { false }
    
    // [极限内存节约]：极大地缩减缩略图的占用大小和缓存数量，以空间换取极低的常驻内存
    var thumbnailMaxEdge: CGFloat { 320 }
    
    var delaysNavigationJumps: Bool { true }
    
    var aggressivePurgeOnClose: Bool { true } // 关文档必须清理全部缓存
    var allowsHibernation: Bool { true }
}
