import Foundation
import os

/// 单一系统压力入口：优先回收正文预热图像，按压力级别调整缩略图预算。
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
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        
        source.setEventHandler { [weak self] in
            let event = self?.memoryPressureSource?.data ?? []
            if event.contains(.critical) {
                self?.handleMemoryPressure(level: "Critical")
            } else if event.contains(.warning) {
                self?.handleMemoryPressure(level: "Warning")
            } else if event.contains(.normal) {
                ThumbnailStore.shared.trim(to: ThumbnailStore.shared.byteLimit)
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
        
        // 全应用只保留一个压力监听器。可见行仍持有正在显示的图像；
        // 缩略图预算逐级收缩，大幅正文缓存暂停预热，避免清理后立即再次生成。
        let limit = level == "Critical" ? 32 : 96
        ThumbnailStore.shared.trim(to: limit * 1024 * 1024)
        for weakState in AppState.allInstances {
            weakState.value?.pdfView.scanCache.removeAll(pauseFor: 30)
        }
    }
    
}
