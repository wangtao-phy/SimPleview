import Foundation
import Combine
import os

/// 内存大管家 (Memory Manager)
/// 专门负责监听底层操作系统的物理内存压力，执行被动释放（被系统警告时）和主动释放（文档关闭时）。
final class MemoryManager {
    static let shared = MemoryManager()
    
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SimpleView", category: "MemoryManager")
    
    private init() {
        startListening()
    }
    
    /// 开始监听系统物理内存压力
    private func startListening() {
        // macOS 和 iOS 通用的底层物理内存压力监听
        // .warning: 内存开始紧张
        // .critical: 极度危险，如果不立即释放很可能被系统强制 Kill
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        
        source.setEventHandler { [weak self] in
            let event = source.data
            if event.contains(.warning) {
                self?.handleMemoryPressure(level: "Warning")
            }
            if event.contains(.critical) {
                self?.handleMemoryPressure(level: "Critical")
            }
        }
        
        source.resume()
        self.memoryPressureSource = source
    }
    
    deinit {
        memoryPressureSource?.cancel()
    }
    
    /// 当收到系统警报时触发
    private func handleMemoryPressure(level: String) {
        logger.warning("🚨 [MemoryManager] Received System Memory Pressure: \(level)")
        
        // 我们听从用户的要求：无论什么模式，都不直接置空 PDFView 实例（因为那会破坏阅读体验）。
        // 我们只做“最安全的极限操作”：清理后台一切闲置缓存。
        
        // 1. 强行砍掉缩略图渲染队列和图片池
        // 因为就算当前在“性能模式”保活了 500 张图，在系统要命的关头，也必须让步。
        for weakState in AppState.allInstances {
            if let state = weakState.value {
                state.thumbnailManager.clearCache()
            }
        }
        
        logger.warning("✅ [MemoryManager] Aggressively purged all background caches to survive.")
    }
}
