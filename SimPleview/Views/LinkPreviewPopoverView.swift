import SwiftUI
import os
@preconcurrency import PDFKit
#if os(macOS)
import AppKit

struct LinkPreviewPopoverView: View {
    let destination: PDFDestination?
    var renderSource: PDFRenderSource?
    var onOpenDestination: (() -> Void)?
    var onHoverStateChanged: ((Bool) -> Void)?
    
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @State private var previewImage: NSImage?
    @State private var previewFailed = false
    @Environment(\.displayScale) private var displayScale
    @State private var attempt = 0

    var a: CGFloat {
        let width = destination?.page?.bounds(for: .cropBox).width ?? 800
        return width.isFinite && width > 0 ? min(width, 1200) : 800
    }
    
    var innerWidth: CGFloat { a * 1.5 }
    // cropHeight was a / 3.0, so innerHeight is (a / 3.0) * 1.5
    var innerHeight: CGFloat { (a / 3.0) * 1.5 }
    
    var outerWidth: CGFloat { innerWidth + 100.0 }
    var outerHeight: CGFloat { innerHeight }
        
    var body: some View {
        VStack(spacing: 0) {
            if destination != nil {
                // Internal Document Destination Preview (Equation, Reference)
                if let img = previewImage {
                    SelectableImageView(image: img)
                        .frame(width: innerWidth, height: innerHeight)
                } else if previewFailed {
                    VStack(spacing: 12) {
                        Text(L.s("Link Preview Unavailable", language))
                            .foregroundStyle(.secondary)
                        Button(L.s("Retry Link Preview", language)) { attempt += 1 }
                        if let onOpenDestination {
                            Button(L.s("Go to Link Destination", language), action: onOpenDestination)
                        }
                    }
                    .frame(width: innerWidth, height: innerHeight)
                } else {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    .frame(width: innerWidth, height: innerHeight) 
                }
            } else {
                Text(L.s("Unknown Link", language))
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
        .task(id: attempt) { await generateThumbnail() }
    }
    
    private func generateThumbnail() async {
        previewImage = nil
        previewFailed = false
        guard !Task.isCancelled else { return }
        guard let dest = destination, let page = dest.page,
              let input = PDFPageRenderInput.capture(page, source: renderSource) else {
            previewFailed = true
            return
        }
        let image = await LinkPreviewRenderer.image(input: input, point: dest.point, scale: 1.5 * displayScale,
            includeAnnotations: page.annotations.contains {
                $0.type != "Link" && ($0.shouldDisplay || StandardInk.isScreenHidden($0))
            })
        guard !Task.isCancelled else { return }
        guard let image else { previewFailed = true; return }
        previewImage = NSImage(cgImage: image, size: NSSize(width: innerWidth, height: innerHeight))
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
