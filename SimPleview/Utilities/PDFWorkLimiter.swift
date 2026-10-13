import Foundation

/// 打开多份文档时限制解析峰值；等待任务挂起，不占线程，也不阻塞主线程。
/// 加载优先于全文统计，两种工作分别限流，统计不能拖住用户正在打开的文件。
actor PDFWorkLimiter {
    nonisolated static let loading = PDFWorkLimiter(limit: 2)
    nonisolated static let statistics = PDFWorkLimiter(limit: 1)
    private let limit: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit { active += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume(returning: true) }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(returning: false)
    }
}
