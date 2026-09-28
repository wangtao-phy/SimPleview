import Metal

/// 编译服务的状态只决定使用哪种显示方式，不能决定 PDF 是否允许打开。
/// 驱动调用可能长时间不返回，因此调用者最多等两秒；探测每次启动只运行
/// 一次，超时后不重复创建后台编译任务，也不阻塞文件读取和界面操作。
@MainActor enum NativeRenderingCheck {
    private static let availability = Task<Bool, Never> { @MainActor in
        await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            let probe = Task.detached(priority: .utility) {
                guard let device = MTLCreateSystemDefaultDevice() else { return false }
                return (try? device.makeLibrary(source: """
                    #include <metal_stdlib>
                    using namespace metal;
                    kernel void simpleview_render_check() {}
                    """, options: nil))?.makeFunction(name: "simpleview_render_check") != nil
            }
            Task { @MainActor in reply.finish(await probe.value) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                reply.finish(false)
            }
        }
    }

    static func isAvailable() async -> Bool { await availability.value }

    @MainActor private final class Reply {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ available: Bool) {
            // 探测与超时可能同时完成；主线程串行取走 continuation，只恢复一次。
            let waiting = continuation
            continuation = nil
            waiting?.resume(returning: available)
        }
    }
}
