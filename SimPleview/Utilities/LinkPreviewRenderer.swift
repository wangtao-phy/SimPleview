import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@preconcurrency import PDFKit

/// 系统 PDF 解码不能在线程内强制取消。每次预览由独立工作进程完成，
/// 超时/关闭浮窗只结束本应用启动的那个进程，不触碰系统服务或阅读窗口。
nonisolated enum LinkPreviewRenderer {
    static let argument = "--simpleview-link-preview"
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    struct Request: Codable, Sendable {
        let index: Int
        let y: Double
        let scale: Double
        var includeAnnotations = false
    }

    static func image(input: PDFPageRenderInput, point: CGPoint, scale: CGFloat, includeAnnotations: Bool) async -> CGImage? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let job = Job(executable: executable)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    let image = autoreleasepool {
                        job.run(input: input, request: Request(index: input.index,
                            y: point.y.isFinite ? point.y : Double.greatestFiniteMagnitude, scale: scale, includeAnnotations: includeAnnotations))
                    }
                    continuation.resume(returning: image)
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
                // 仅持有本任务创建的 Process。强制结束卡在系统解码中的子进程，
                // 不让不可取消的系统调用堵住队列，也不累积后台线程。
                if let process = $0.process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        func run(input: PDFPageRenderInput, request: Request, timeout: TimeInterval = 6) -> CGImage? {
            guard !state.withLock({ $0.cancelled }) else { return nil }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleview-link-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try input.data.write(to: directory.appendingPathComponent("input.pdf"))
                try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("request.json"))
                let process = Process(), finished = DispatchSemaphore(value: 0)
                process.executableURL = executable
                process.arguments = [LinkPreviewRenderer.argument, directory.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { _ in finished.signal() }
                let started = try state.withLock { state in
                    guard !state.cancelled else { return false }
                    try process.run()
                    state.process = process
                    return true
                }
                guard started else { return nil }
                defer { state.withLock { $0.process = nil } }
                guard finished.wait(timeout: .now() + timeout) == .success else {
                    cancel()
                    _ = finished.wait(timeout: .now() + 1)
                    return nil
                }
                guard !state.withLock({ $0.cancelled }), process.terminationStatus == 0 else { return nil }
                // ImageIO 默认延迟解码。由 URL 创建的 CGImage 可能在这里返回后
                // 才读取 PNG，此时 defer 已删除临时文件，最终只画出黑色像素。
                // 先取得独立的内存字节并立即解码，返回值不再依赖临时文件的寿命。
                let bytes = try Data(contentsOf: directory.appendingPathComponent("output.png"))
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            } catch { return nil }
        }
    }

    /// 工作模式在 SwiftUI/AppDelegate 初始化之前运行，不能恢复窗口或启动其它业务。
    static func runWorkerIfRequested() {
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == argument else { return }
        let directory = URL(fileURLWithPath: args[2], isDirectory: true)
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: directory.appendingPathComponent("request.json")))
            // 有可见标注时只在子进程打开 PDFKit 副本以补画标注，正文仍走 CoreGraphics。
            let annotations = request.includeAnnotations
                ? PDFDocument(url: directory.appendingPathComponent("input.pdf")) : nil
            defer { withExtendedLifetime(annotations) {} }
            guard let document = CGPDFDocument(directory.appendingPathComponent("input.pdf") as CFURL),
                  request.index >= 0, request.index < document.numberOfPages,
                  let page = document.page(at: request.index + 1),
                  let image = render(page: page, y: request.y, scale: request.scale, annotations: annotations?.page(at: request.index)?.annotations ?? []),
                  let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("output.png") as CFURL,
                      UTType.png.identifier as CFString, 1, nil) else { exit(1) }
            CGImageDestinationAddImage(output, image, nil)
            exit(CGImageDestinationFinalize(output) ? 0 : 1)
        } catch { exit(1) }
    }

    /// CoreGraphics 直接绘制 PDF 页面，不调用 PDFKit 的标注/文字分析与系统预览服务。
    static func render(page: CGPDFPage, y: CGFloat, scale: CGFloat, annotations: [PDFAnnotation] = []) -> CGImage? {
        let bounds = page.getBoxRect(.cropBox)
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.maxY.isFinite,
              bounds.width.isFinite, bounds.width > 0, bounds.height.isFinite, bounds.height > 0,
              scale.isFinite, scale > 0 else { return nil }
        let y = y.isFinite && (bounds.minY...bounds.maxY).contains(y) ? y : bounds.maxY
        let height = min(bounds.height, bounds.width / 3)
        let crop = CGRect(x: bounds.minX, y: min(bounds.maxY-height, max(bounds.minY, y-height+40)), width: bounds.width, height: height)
        let scale = min(scale, 4096 / max(crop.width, crop.height))
        let w = max(1, Int(ceil(crop.width*scale))), h = max(1, Int(ceil(crop.height*scale)))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -crop.minX, y: -crop.minY)
        context.drawPDFPage(page)
        for annotation in annotations where annotation.shouldDisplay && annotation.type != "Link" {
            annotation.draw(with: .cropBox, in: context)
        }
        return context.makeImage()
    }
}
