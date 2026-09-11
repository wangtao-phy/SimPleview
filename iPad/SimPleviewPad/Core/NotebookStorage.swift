import Foundation
import PDFKit
import PencilKit
import ImageIO
import UniformTypeIdentifiers

struct PadFileVersion: Equatable, Sendable {
    let size: Int
    let modified: Date
    let identity: UInt64
    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        modified = attributes[.modificationDate] as? Date ?? .distantPast
        identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

struct PadSaveSnapshot: Sendable {
    let background: Data
    let drawings: [Int: PKDrawing]
}

/// 文档解析、外观流生成和磁盘写入都在串行执行器内完成。
/// 不接触主线程的 PDFDocument / PKCanvasView，避免保存阻塞书写或跨线程读写 PDFKit。
actor NotebookStorage {
    private let recoveryDirectory: URL?
    private let recoveryID = UUID().uuidString
    init(recoveryDirectory: URL? = nil) { self.recoveryDirectory = recoveryDirectory }
    /// 图像仅用于本地缩略图和用户主动发起的视觉读取；PDF 保存始终使用矢量。
    func images(_ snapshot: PadSaveSnapshot, pages: [Int], maximumDimension: CGFloat = 1536) throws -> [AIImageInput] {
        guard let document = PDFDocument(data: snapshot.background), pages.count <= 2 else { throw PadError.message("页面批次无效。") }
        return try pages.map { index in
            try Task.checkCancellation()
            guard let page = document.page(at: index), let reference = page.pageRef else { throw PadError.message("无法读取页面。") }
            let bounds = page.bounds(for: .cropBox), rotated = page.rotation % 180 != 0
            let size = rotated ? CGSize(width: bounds.height,height: bounds.width) : bounds.size
            let scale = min(2,maximumDimension/max(size.width,size.height))
            let width = max(1,Int(size.width*scale)), height = max(1,Int(size.height*scale))
            guard let context = CGContext(data: nil, width: width,height: height,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw PadError.message("页面图像分配失败。") }
            context.setFillColor(CGColor(gray: 1,alpha: 1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
            context.concatenate(reference.getDrawingTransform(.cropBox,rect:CGRect(x:0,y:0,width:width,height:height),rotate:0,preserveAspectRatio:true))
            page.draw(with: .cropBox, to: context)
            if let drawing = snapshot.drawings[index] { VectorInk.draw(try VectorInk.shapes(from:drawing), pageBounds:bounds,in:context) }
            guard let image = context.makeImage() else { throw PadError.message("页面渲染失败。") }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw PadError.message("JPEG 编码失败。") }
            CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PadError.message("JPEG 编码失败。") }
            return AIImageInput(pageNumber:index+1,jpeg:data as Data)
        }
    }
    func search(_ data: Data, text: String) throws -> [Int] {
        guard let document = PDFDocument(data: data) else { return [] }
        var result: [Int] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            if document.page(at: index)?.string?.localizedStandardContains(text) == true { result.append(index) }
            if result.count >= 200 { break }
        }
        return result
    }
    func read(_ url: URL) throws -> (Data, PadFileVersion) {
        var error: NSError?
        var result: Result<(Data, PadFileVersion), Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { target in
            result = Result {
                let data = try Data(contentsOf: target)
                guard !data.isEmpty else { throw PadError.message("PDF 文件为空，或尚未从云端下载完成。") }
                return (data, try PadFileVersion(target))
            }
        }
        if let error { throw error }
        guard let result else { throw PadError.message("无法获得文件读取权限。") }
        return try result.get()
    }

    func render(_ snapshot: PadSaveSnapshot, flattened: Bool = false) throws -> Data {
        guard let document = PDFDocument(data: snapshot.background), !document.isLocked else {
            throw PadError.message("PDF 无法读取或尚未解锁。")
        }
        if flattened { return try flattenedData(snapshot, document: document) }
        var encodedDrawings: [Int: String] = [:]
        for (index, drawing) in snapshot.drawings where !drawing.strokes.isEmpty {
            guard let page = document.page(at: index) else { throw PadError.message("笔迹对应的页面不存在。") }
            let annotations = try VectorInk.annotations(drawing: drawing, bounds: page.bounds(for: .cropBox))
            encodedDrawings[index] = annotations.first?.value(forAnnotationKey: VectorInk.drawingKey) as? String
            for annotation in annotations { page.addAnnotation(annotation) }
        }
        guard let data = document.dataRepresentation(), let reopened = PDFDocument(data: data),
              reopened.pageCount == document.pageCount else { throw PadError.message("PDF 保存后校验失败。") }
        for (index, drawing) in snapshot.drawings where !drawing.strokes.isEmpty {
            guard let page = reopened.page(at:index),
                  let encoded = encodedDrawings[index],
                  let annotation = page.annotations.first(where: {
                      $0.value(forAnnotationKey: VectorInk.drawingKey) as? String == encoded
                  }), let restored = try VectorInk.drawing(in:annotation),
                  restored.strokes.count == drawing.strokes.count else {
                throw PadError.message("笔迹编辑数据未完整保留，原文件未替换。")
            }
            // 附件完整不代表标准 PDF 笔迹完整。必须通过实际重开时的几何比对，
            // 才能替换原文件，防止框架静默丢弃 InkList 而留下空白标注。
            guard try VectorInk.takeEditableDrawing(from:page).strokes.count == drawing.strokes.count else {
                throw PadError.message("标准 PDF 笔迹校验失败，原文件未替换。")
            }
        }
        return data
    }

    /// 通用分享副本把笔迹直接写成页面绘图指令，绕开第三方阅读器的标注缓存。
    /// 原始页面仍通过 CoreGraphics 引用矢量内容，不先截图再生成 PDF。
    private func flattenedData(_ snapshot:PadSaveSnapshot, document:PDFDocument) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data:data), let context = CGContext(consumer:consumer,mediaBox:nil,nil) else {
            throw PadError.message("无法创建通用 PDF。")
        }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at:index), let reference = page.pageRef else { throw PadError.message("无法读取页面。") }
            let bounds=page.bounds(for:.cropBox), sideways=page.rotation % 180 != 0
            var box=CGRect(origin:.zero,size:sideways ? CGSize(width:bounds.height,height:bounds.width) : bounds.size)
            let media=NSData(bytes:&box,length:MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String:media] as CFDictionary)
            context.saveGState()
            context.concatenate(reference.getDrawingTransform(.cropBox,rect:box,rotate:0,preserveAspectRatio:true))
            context.drawPDFPage(reference)
            for annotation in page.annotations where annotation.shouldDisplay { annotation.draw(with:.cropBox,in:context) }
            if let drawing=snapshot.drawings[index] { VectorInk.draw(try VectorInk.shapes(from:drawing),pageBounds:bounds,in:context) }
            context.restoreGState();context.endPDFPage()
        }
        context.closePDF()
        guard PDFDocument(data:data as Data)?.pageCount == document.pageCount else {throw PadError.message("通用 PDF 校验失败。")}
        return data as Data
    }

    func save(_ snapshot: PadSaveSnapshot, to url: URL, expected: PadFileVersion) throws -> PadFileVersion {
        let data = try render(snapshot)
        var recovery: URL?
        if let recoveryDirectory {
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            let name = String(url.deletingPathExtension().lastPathComponent.prefix(80)) + "-" + recoveryID + ".pdf"
            let candidate = recoveryDirectory.appendingPathComponent(name)
            // 先落盘可直接打开的恢复副本；写入失败或进程终止时不依赖内存找回笔记。
            try data.write(to:candidate,options:.atomic)
            recovery = candidate
        }
        var error: NSError?
        var result: Result<PadFileVersion, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
            result = Result {
                // 在协调区内再次检查版本，避免两台设备或两个窗口相互静默覆盖。
                guard try PadFileVersion(target) == expected else {
                    throw PadError.message("文件已在其他窗口或设备修改。当前笔迹仍保留，请另存副本后再重新打开。")
                }
                // 单文件授权不等于父目录授权。只在协调区内向提供商给出的
                // target 原子写入，不预先在原目录创建另一个无授权的临时 PDF。
                try data.write(to: target, options: .atomic)
                return try PadFileVersion(target)
            }
        }
        if let error { throw error }
        guard let result else { throw PadError.message("无法获得文件写入权限。") }
        let version = try result.get()
        if let recovery { try? FileManager.default.removeItem(at:recovery) }
        return version
    }
}
