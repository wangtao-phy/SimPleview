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
    /// 缩略图内存缓存最大数量
    var thumbnailCountLimit: Int { get }
    /// 缩略图最大生成边长
    var thumbnailMaxEdge: CGFloat { get }
    /// 是否开启强引用保活机制（防止系统过度清理）
    var usesStrongCacheRetention: Bool { get }
    
    // MARK: - 交互级策略
    /// 侧边栏极速滚动时，是否为了防抖而延迟跳转（防渲染风暴）
    var delaysNavigationJumps: Bool { get }
    /// 是否实时向 PDF 写入批注（所见即所得 vs 关闭时才写入）
    var syncAnnotationsInRealtime: Bool { get }
    
    // MARK: - 休眠级策略
    /// 文档关闭时，是否要激进地清空整个 Thumbnail 缓存？
    var aggressivePurgeOnClose: Bool { get }
    /// 是否允许休眠
    var allowsHibernation: Bool { get }
}

/// 性能模式：对标 macOS Preview.app
/// 极高的渲染质量、激进的内存占用、实时响应、关闭防抖延迟。
struct PerformanceMemoryPolicy: MemoryPolicy {
    var interpolationQuality: PDFInterpolationQuality { .high }
    var pageShadowsEnabled: Bool { true }
    
    var thumbnailCountLimit: Int { 500 }
    var thumbnailMaxEdge: CGFloat { 1024 }
    var usesStrongCacheRetention: Bool { true }
    
    var delaysNavigationJumps: Bool { false }
    var syncAnnotationsInRealtime: Bool { true }
    
    var aggressivePurgeOnClose: Bool { false } // 关文档不清理，再次打开可能秒开
    var allowsHibernation: Bool { false }
}

/// 节约模式：对标 Skim
/// 降级渲染质量、较小的内存上限、遇到压力或关闭文档立即回收、极速滚动开启防抖。
struct SavingMemoryPolicy: MemoryPolicy {
    var interpolationQuality: PDFInterpolationQuality { .low }
    var pageShadowsEnabled: Bool { false }
    
    var thumbnailCountLimit: Int { 50 }
    var thumbnailMaxEdge: CGFloat { 256 }
    var usesStrongCacheRetention: Bool { false }
    
    var delaysNavigationJumps: Bool { true }
    var syncAnnotationsInRealtime: Bool { false }
    
    var aggressivePurgeOnClose: Bool { true } // 关文档必须清理全部缓存
    var allowsHibernation: Bool { true }
}
