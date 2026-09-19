import SwiftUI
import os
@preconcurrency import PDFKit
#if os(macOS)
import AppKit

struct LinkPreviewPopoverView: View {
    let annotation: PDFAnnotation
    var onHoverStateChanged: ((Bool) -> Void)?
    
    @State private var previewImage: NSImage?
    @Environment(\.displayScale) private var displayScale
    private static let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    
    // Resolve Destination either from direct property or action
    var resolvedDestination: PDFDestination? {
        if let d = annotation.destination { return d }
        if let action = annotation.action as? PDFActionGoTo { return action.destination }
        return nil
    }
    
    var a: CGFloat {
        resolvedDestination?.page?.bounds(for: .cropBox).width ?? 800.0
    }
    
    var innerWidth: CGFloat { a * 1.5 }
    // cropHeight was a / 3.0, so innerHeight is (a / 3.0) * 1.5
    var innerHeight: CGFloat { (a / 3.0) * 1.5 }
    
    var outerWidth: CGFloat { innerWidth + 100.0 }
    var outerHeight: CGFloat { innerHeight }
        
    var body: some View {
        VStack(spacing: 0) {
            if resolvedDestination != nil {
                // Internal Document Destination Preview (Equation, Reference)
                if let img = previewImage {
                    SelectableImageView(image: img)
                        .frame(width: innerWidth, height: innerHeight)
                } else {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    .frame(width: innerWidth, height: innerHeight) 
                }
            } else {
                Text("Unknown Link")
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .frame(width: outerWidth, height: outerHeight) 
        .background(Color(NSColor.windowBackgroundColor)) 
        .cornerRadius(8)
        .onHover { hovering in
            onHoverStateChanged?(hovering)
        }
        .task(id: ObjectIdentifier(annotation)) { await generateThumbnail() }
    }
    
    private func generateThumbnail() async {
        guard !Task.isCancelled, let dest = resolvedDestination, let page = dest.page,
              let data = StandardInk.exportData(of: page) else { return }
        let point = dest.point, scale = 1.5 * displayScale
        let work = BlockOperation()
        let result = OSAllocatedUnfairLock<CGImage?>(initialState: nil)
        work.addExecutionBlock { [weak work] in
            guard work?.isCancelled == false else { return }
            let image = autoreleasepool { Self.render(data: data, point: point, scale: scale) }
            result.withLock { $0 = image }
        }
        // 关闭弹窗会取消 .task；未开始的预览不再绘制，已开始的图像不回填。
        // 共用串行队列，快速扫过多个链接时不并发解码多份 PDF。
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                work.completionBlock = { continuation.resume(returning: result.withLock { $0 }) }
                Self.renderQueue.addOperation(work)
            }
        } onCancel: { work.cancel() }
        guard !Task.isCancelled, let image else { return }
        previewImage = NSImage(cgImage: image, size: NSSize(width: innerWidth, height: innerHeight))
    }

    nonisolated private static func render(data: Data, point: CGPoint, scale: CGFloat) -> CGImage? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        defer { withExtendedLifetime(document) {} }
        let bounds = page.bounds(for: .cropBox)
        let crop = CGRect(x: bounds.minX, y: max(bounds.minY, point.y - bounds.width / 3 + 40),
                          width: bounds.width, height: bounds.width / 3)
        guard crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0,
              scale.isFinite, scale > 0 else { return nil }
        let scale = min(scale, 4096 / max(crop.width, crop.height))
        let width = Int(ceil(crop.width * scale)), height = Int(ceil(crop.height * scale))
        // 后台只使用独立 PDF 和显式像素缓冲，避免 lockFocus 隐式分配
        // 多倍率 AppKit 图像。分辨率对应弹窗实际大小和屏幕像素密度。
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

}

#if os(macOS)
import VisionKit

struct SelectableImageView: NSViewRepresentable {
    let image: NSImage
    
    @MainActor final class Coordinator {
        weak var imageView: NSImageView?
        weak var overlay: ImageAnalysisOverlayView?
        var image: NSImage?
        var task: Task<Void, Never>?
        let analyzer = ImageAnalyzer()

        func update(_ image: NSImage) {
            guard self.image !== image else { return }
            task?.cancel()
            self.image = image
            imageView?.image = image
            overlay?.analysis = nil
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let analyzer = analyzer
            task = Task { [weak self, weak overlay] in
                do {
                    let analysis = try await analyzer.analyze(cg, orientation: .up, configuration: .init([.text]))
                    guard !Task.isCancelled else { return }
                    overlay?.analysis = analysis
                    self?.task = nil
                } catch {
                    if !Task.isCancelled { Logger.view.error("VisionKit analysis failed: \(error)") }
                }
            }
        }
        func stop() {
            task?.cancel(); task = nil
            overlay?.analysis = nil; overlay?.trackingImageView = nil
            imageView?.image = nil; image = nil
        }
        deinit { task?.cancel() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        // SwiftUI 即使暂存原生容器，关闭后的图像与文字识别也立即释放。
        coordinator.stop()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        // Prevent imageView from pushing its frame beyond the SwiftUI specified bounds
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        
        if #available(macOS 13.0, *) {
            let overlay = ImageAnalysisOverlayView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            // Allow selecting text and copying
            overlay.preferredInteractionTypes = .textSelection
            overlay.trackingImageView = imageView
            container.addSubview(overlay)
            
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: imageView.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)
            ])
            
            context.coordinator.overlay = overlay

        }
        
        context.coordinator.imageView = imageView
        context.coordinator.update(image)
        return container
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(image)
    }
}
#endif
#endif
