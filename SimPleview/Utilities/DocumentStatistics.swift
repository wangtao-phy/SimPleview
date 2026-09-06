import Foundation
import PDFKit

nonisolated struct DocumentStatistics: Sendable {
    var englishWords = 0
    var chineseCharacters = 0

    /// 本方法只在独立工作任务中调用，自己打开自己的 PDFDocument；不会把
    /// AppState 或正在显示的 PDFPage 保留到后台。逐页释放临时文本/解析对象。
    static func read(url: URL) -> Self? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isEncrypted { document.unlock(withPassword: "") }
        guard !document.isLocked else { return nil }
        var result = Self()
        for index in 0..<document.pageCount {
            guard !Task.isCancelled else { return nil }
            autoreleasepool {
                guard let text = document.page(at: index)?.string else { return }
                result.englishWords += text.split(whereSeparator: { !$0.isASCII || !$0.isLetter }).count
                result.chineseCharacters += text.unicodeScalars.filter {
                    (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                    || (0x20000...0x3134F).contains($0.value)
                }.count
            }
        }
        return result
    }
}
