import Foundation
import PDFKit

/// 保存事务只在文档所有者（主执行器）中运行。先生成同目录临时文件并验证
/// 能重新打开，再协调替换原文件；写入失败不会先截断正在读取的原始 PDF。
/// PDFKit 可能重建字体/外观，因此复杂文档仍需做保存前后的渲染回归。
@MainActor
enum AtomicPDFWriter {
    /// 自动保存必须确认磁盘仍是本窗口读取/上次保存的版本，避免静默覆盖
    /// iCloud 或另一窗口刚同步来的文件。比较在文件协调区内、替换之前完成。
    struct FileVersion: Equatable {
        let modified: Date
        let size: UInt64
        let inode: UInt64

        init(url: URL) throws {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let modified = values[.modificationDate] as? Date,
                  let size = values[.size] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber else {
                throw CocoaError(.fileReadUnknown)
            }
            self.modified = modified; self.size = size.uint64Value; self.inode = inode.uint64Value
        }
    }

    static func write(_ document: PDFDocument, to destination: URL, expectedVersion: FileVersion? = nil) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".SimPleview-\(UUID().uuidString).pdf")
        let visibleCopy = destination.deletingLastPathComponent()
            .appendingPathComponent(".SimPleview-\(UUID().uuidString)-visible.pdf")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: visibleCopy)
        }
        guard document.write(to: temporary), let verification = PDFDocument(url: temporary) else {
            throw validationError("无法写入或重新打开临时 PDF")
        }
        try validateAnnotations(from: document, in: verification)
        var candidate = temporary
        if StandardInk.restoreExportVisibility(in: verification) {
            // 在验证副本上恢复文件可见性，活动文档始终保持原生位图层关闭。
            // 使用第二个临时文件，不能覆写 verification 正在读取的文件。
            guard verification.write(to: visibleCopy),
                  let reopened = PDFDocument(url: visibleCopy) else { throw validationError("无法写入可见标注副本") }
            try validateAnnotations(from: document, in: reopened)
            candidate = visibleCopy
        }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing,
                                        error: &coordinationError) { target in
            do {
                if let expectedVersion, try FileVersion(url: target) != expectedVersion {
                    throw NSError(domain: "SimPleview.Save", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "磁盘文件已在外部更新，已暂停自动保存以保留两边修改。请先另存副本或确认需要保留的版本。"])
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: candidate)
                } else {
                    try FileManager.default.moveItem(at: candidate, to: target)
                }
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }

    /// 验证的不只是页数。标注数量/类型及本应用的分块矢量数据必须经过
    /// 写入、重新解析后仍完整，才允许替换原文件；不栅格化页面，不嵌入截图。
    private static func validateAnnotations(from source: PDFDocument, in saved: PDFDocument) throws {
        guard source.pageCount == saved.pageCount else { throw validationError("页数发生变化") }
        for index in 0..<source.pageCount {
            guard let original = source.page(at: index), let copy = saved.page(at: index) else { throw validationError("无法读取页面") }
            let before = original.annotations, after = copy.annotations
            guard before.map({ $0.type ?? "" }).sorted() == after.map({ $0.type ?? "" }).sorted() else { throw validationError("标注数量或类型发生变化") }
            for annotation in before where annotation.type == "Ink" && StandardInk.isAppInk(annotation) {
                guard let restored = after.first(where: { $0.userName == annotation.userName && $0.type == annotation.type }) else { throw validationError("缺少原始标注标识") }
                for chunk in 0..<1024 {
                    let key = PDFAnnotationKey(rawValue: chunk == 0 ? "/SimPlePath" : "/SimPlePath\(chunk)")
                    guard let value = annotation.value(forAnnotationKey: key) as? String else { break }
                    guard restored.value(forAnnotationKey: key) as? String == value else { throw validationError("矢量路径未完整保留") }
                }
                if annotation.type == "Ink", annotation.paths?.isEmpty == false,
                   restored.paths?.count != annotation.paths?.count { throw validationError("标准手绘笔划数量发生变化") }
            }
        }
    }

    private static func validationError(_ detail: String) -> NSError {
        NSError(domain: "SimPleview.Save", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "保存验证未通过：" + detail + "。原文件未替换，修改仍保留在窗口中。"])
    }

}
