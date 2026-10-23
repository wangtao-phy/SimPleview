import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@preconcurrency import PDFKit

/// 原始 PDF 只在本应用的独立工作进程解码。关闭预览会结束该任务；失败时
/// 至多重新启动一次工作进程，不重启系统服务，也不影响阅读窗口或其它应用。
nonisolated enum LinkPreviewRenderer {
    static let argument = "--simpleview-link-preview"
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    /// 位图负责显示，独立单页 PDF 负责原生文字选择；二者使用相同的裁剪和旋转。
    /// CGImage 在创建时完成解码，之后只读，不依赖已经删除的临时文件。
    struct Preview: @unchecked Sendable {
        let image: CGImage
        let pdfData: Data
    }

    struct Request: Codable, Sendable {
        let index: Int
        let x: Double
        let y: Double
        let scale: Double
        var includeAnnotations = false
    }

    static func preview(input: PDFPageRenderInput, point: CGPoint, scale: CGFloat,
                        includeAnnotations: Bool) async -> Preview? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let job = Job(executable: executable)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    let preview = autoreleasepool {
                        job.run(input: input, request: Request(index: input.index,
                            x: point.x.isFinite ? point.x : Double.greatestFiniteMagnitude,
                            y: point.y.isFinite ? point.y : Double.greatestFiniteMagnitude,
                            scale: scale, includeAnnotations: includeAnnotations))
                    }
                    continuation.resume(returning: preview)
                }
            }
        } onCancel: { job.cancel() }
    }

    final class Job: @unchecked Sendable {
        private struct State { var cancelled = false; var process: Process? }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let executable: URL
        init(executable: URL) { self.executable = executable }

        func cancel() {
            state.withLock {
                $0.cancelled = true
                if let process = $0.process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        func run(input: PDFPageRenderInput, request: Request, timeout: TimeInterval = 6) -> Preview? {
            for _ in 0..<2 {
                guard !state.withLock({ $0.cancelled }) else { return nil }
                if let result = attempt(input: input, request: request, timeout: timeout) { return result }
            }
            return nil
        }

        private func attempt(input: PDFPageRenderInput, request: Request, timeout: TimeInterval) -> Preview? {
            let deadline = DispatchTime.now() + timeout
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleview-link-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                // 写入也在后台；完成后检查总时限，不能写完大文件才开始计算超时。
                try input.data.write(to: directory.appendingPathComponent("input.pdf"))
                guard !state.withLock({ $0.cancelled }), DispatchTime.now() < deadline else { return nil }
                try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("request.json"))
                let process = Process(), finished = DispatchSemaphore(value: 0)
                process.executableURL = executable
                process.arguments = [LinkPreviewRenderer.argument, directory.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { _ in finished.signal() }
                let started = try state.withLock { state in
                    guard !state.cancelled, DispatchTime.now() < deadline else { return false }
                    try process.run()
                    state.process = process
                    return true
                }
                guard started else { return nil }
                defer { state.withLock { $0.process = nil } }
                guard finished.wait(timeout: deadline) == .success else {
                    // 仅结束这一轮的子进程；保留任务本身，允许下一轮重新启动。
                    state.withLock {
                        if let process = $0.process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    _ = finished.wait(timeout: .now() + 1)
                    return nil
                }
                guard !state.withLock({ $0.cancelled }), process.terminationStatus == 0 else { return nil }
                let pdfData = try Data(contentsOf: directory.appendingPathComponent("output.pdf"))
                let bytes = try Data(contentsOf: directory.appendingPathComponent("output.png"))
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0,
                          [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      !state.withLock({ $0.cancelled }) else { return nil }
                return Preview(image: image, pdfData: pdfData)
            } catch { return nil }
        }
    }

    /// 在 SwiftUI/AppDelegate 初始化之前运行，不恢复窗口或启动其它业务。
    static func runWorkerIfRequested() {
        let args = CommandLine.arguments
        guard args.count > 1, args[1] == argument else { return }
        guard args.count == 3 else { exit(1) } // 无效 worker 请求不能进入主应用或写入运行标记。
        let directory = URL(fileURLWithPath: args[2], isDirectory: true)
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: directory.appendingPathComponent("request.json")))
            let inputURL = directory.appendingPathComponent("input.pdf")
            let annotations = request.includeAnnotations ? PDFDocument(url: inputURL) : nil
            defer { withExtendedLifetime(annotations) {} }
            guard let document = CGPDFDocument(inputURL as CFURL),
                  request.index >= 0, request.index < document.numberOfPages,
                  let page = document.page(at: request.index + 1),
                  let preview = render(page: page, point: CGPoint(x: request.x, y: request.y), scale: request.scale,
                      annotations: annotations?.page(at: request.index)?.annotations ?? []),
                  let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("output.png") as CFURL,
                      UTType.png.identifier as CFString, 1, nil) else { exit(1) }
            try preview.pdfData.write(to: directory.appendingPathComponent("output.pdf"))
            CGImageDestinationAddImage(output, preview.image, nil)
            exit(CGImageDestinationFinalize(output) ? 0 : 1)
        } catch { exit(1) }
    }

    /// 先裁剪成原点为零的单页 PDF，再将该页解码为位图。PDF 输出保留字形、
    /// 字体和文字坐标，复制不需要把已有文字重新交给 OCR 识别。
    static func render(page: CGPDFPage, point: CGPoint, scale: CGFloat,
                       annotations: [PDFAnnotation] = []) -> Preview? {
        let bounds = page.getBoxRect(.cropBox)
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.maxX.isFinite, bounds.maxY.isFinite,
              bounds.width.isFinite, bounds.width > 0, bounds.height.isFinite, bounds.height > 0,
              scale.isFinite, scale > 0 else { return nil }
        let sideways = abs(page.rotationAngle % 180) == 90
        let displayed = CGRect(x: 0, y: 0, width: sideways ? bounds.height : bounds.width,
                               height: sideways ? bounds.width : bounds.height)
        let transform = page.getDrawingTransform(.cropBox, rect: displayed, rotate: 0, preserveAspectRatio: true)
        let validPoint = CGPoint(x: point.x.isFinite && (bounds.minX...bounds.maxX).contains(point.x) ? point.x : bounds.minX,
                                 y: point.y.isFinite && (bounds.minY...bounds.maxY).contains(point.y) ? point.y : bounds.maxY)
        let target = validPoint.applying(transform)
        let height = min(displayed.height, displayed.width / 3)
        let cropY = min(displayed.height - height, max(0, target.y - height + 40))
        var outputBounds = CGRect(x: 0, y: 0, width: displayed.width, height: height)
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &outputBounds, nil) else { return nil }
        pdf.beginPDFPage(nil)
        pdf.setFillColor(CGColor(gray: 1, alpha: 1)); pdf.fill(outputBounds)
        pdf.translateBy(x: 0, y: -cropY)
        pdf.concatenate(transform)
        pdf.drawPDFPage(page)
        for annotation in annotations where annotation.shouldDisplay && annotation.type != "Link" {
            annotation.draw(with: .cropBox, in: pdf)
        }
        pdf.endPDFPage(); pdf.closePDF()
        let data = bytes as Data
        guard let provider = CGDataProvider(data: data as CFData), let cropped = CGPDFDocument(provider),
              let croppedPage = cropped.page(at: 1) else { return nil }
        let scale = min(scale, 4096 / max(outputBounds.width, outputBounds.height))
        let width = max(1, Int(ceil(outputBounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(outputBounds.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(croppedPage)
        guard let image = context.makeImage() else { return nil }
        return Preview(image: image, pdfData: data)
    }
}
