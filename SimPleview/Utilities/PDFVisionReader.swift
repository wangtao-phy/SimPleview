import Foundation
@preconcurrency import PDFKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PDFReadProgress: Codable, Sendable {
    var totalPages: Int
    var completedPages: Int
    var fileName: String
    /// 单页读取保留原文档页码；旧会话没有此字段时按整份 PDF 解释。
    var pageNumber: Int?
}

@MainActor
protocol PDFVisionSource: AnyObject {
    var pageCount: Int { get }
    var fileName: String { get }
    func verify() throws
    func pageData(at index: Int) throws -> Data
}

/// 每次只在主执行器取一页的不可变数据；不把整个大 PDF 复制进内存。
/// 文档实例/编辑版本改变时停止，避免把不同版本的页面混称为“整份 PDF”。
@MainActor
final class AppPDFVisionSource: PDFVisionSource {
    private weak var state: AppState?
    private let document: ObjectIdentifier
    private let revision: UInt
    let pageCount: Int
    let fileName: String
    init(state: AppState) throws {
        guard let document = state.pdfView.document, !document.isLocked, document.pageCount > 0 else {
            throw AIConfigurationError.message("请先打开一个可读取的 PDF。")
        }
        state.pdfView.commitDraftInk()
        self.state = state; self.document = ObjectIdentifier(document)
        revision = state.editRevision; pageCount = document.pageCount; fileName = state.fileName
    }
    func verify() throws {
        guard let state, !state.isClosed, state.editRevision == revision,
              let current = state.pdfView.document, ObjectIdentifier(current) == document,
              current.pageCount == pageCount else {
            throw AIConfigurationError.message("PDF 已修改、重新加载或关闭。读取已停止，请重新读取，避免混用文件版本。")
        }
    }
    func pageData(at index: Int) throws -> Data {
        try verify()
        guard index >= 0, index < pageCount, let page = state?.pdfView.document?.page(at: index),
              let data = StandardInk.exportData(of: page), data.count <= 64 * 1024 * 1024 else {
            throw AIConfigurationError.message("第 \(index + 1) 页无法读取或单页数据超过 64 MiB；未跳过该页。")
        }
        return data
    }
}

nonisolated enum PDFVisionRenderer {
    /// 后台解析自己的单页 PDF，渲染后仅返回 JPEG 值；不共享活动 PDFPage。
    /// 单页像素边长和编码体积都有上限，上一批请求结束后才渲染下一批。
    @concurrent
    static func image(data: Data, pageNumber: Int) async throws -> AIImageInput {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { throw URLError(.cannotDecodeContentData) }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw AIConfigurationError.message("第 \(pageNumber) 页的页面尺寸无效。")
            }
            let rotation = ((page.rotation % 360) + 360) % 360
            let width = rotation == 90 || rotation == 270 ? bounds.height : bounds.width
            let height = rotation == 90 || rotation == 270 ? bounds.width : bounds.height
            let scale = 1536 / max(width, height)
            let size = CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
            let image = page.thumbnail(of: size, for: .cropBox)
            guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw URLError(.cannotDecodeContentData) }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw URLError(.cannotCreateFile) }
            CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length <= 4 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            try Task.checkCancellation()
            return AIImageInput(pageNumber: pageNumber, jpeg: output as Data)
        }
    }
}

/// 只保存本轮的页码与已完成批次笔记，不缓存整本书的图片。
/// 暂停后重做尚未完成的一批，不会跳过只收到一半回答的页面。
@MainActor
final class PDFVisionRun {
    let source: any PDFVisionSource
    let route: AIRoute
    let assistantID: UUID
    let question: String
    let currentPageIndex: Int?
    var requestedPageCount: Int { currentPageIndex == nil ? source.pageCount : 1 }
    func documentIndex(for offset: Int) -> Int { currentPageIndex ?? offset }
    var completedPages = 0
    var notes = ""
    init(source: any PDFVisionSource, route: AIRoute, assistantID: UUID, question: String, currentPageIndex: Int? = nil) {
        self.source = source; self.route = route; self.assistantID = assistantID; self.question = question
        self.currentPageIndex = currentPageIndex
    }
}
