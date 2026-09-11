import Foundation
import Combine

/// 全应用共用一个生成名额（含摘要与 PDF 分批读取）。取消只是发出信号，
/// 必须等旧 Task 真正退出才释放名额，避免“点暂停后立即发送”产生请求重叠。
@MainActor
final class AIRequestGate: ObservableObject {
    static let shared = AIRequestGate()
    @Published private(set) var activeID: UUID?
    @Published private(set) var label = ""
    var isBusy: Bool { activeID != nil }
    func acquire(label: String) throws -> UUID {
        guard activeID == nil else { throw AIConfigurationError.message("正在完成上一轮回答，请先暂停并等待停止后再发送。") }
        let id = UUID(); activeID = id; self.label = label; return id
    }
    func release(_ id: UUID) {
        guard activeID == id else { return }
        activeID = nil; label = ""
    }
}

nonisolated enum AISentencePresentation {
    static func text(_ raw: String, final: Bool = false) -> String {
        if final { return raw }
        // 按结束标点/换行提交完整语句。没有句尾的最后一段留到下一块或结束，
        // 暂停时仍保存原始已收到文本，不能丢掉尚未显示的半句话。
        guard let end = raw.lastIndex(where: { "。！？!?；;\n.".contains($0) }) else { return "" }
        return String(raw[...end])
    }
}
