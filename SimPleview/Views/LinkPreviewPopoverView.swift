import SwiftUI
@preconcurrency import PDFKit
#if os(macOS)
import AppKit

struct LinkPreviewPopoverView: View {
    let annotation: PDFAnnotation
    var onHoverStateChanged: ((Bool) -> Void)?
    
    @State private var previewImage: NSImage?
    
    // Resolve Destination either from direct property or action
    var resolvedDestination: PDFDestination? {
        if let d = annotation.destination { return d }
        if let action = annotation.action as? PDFActionGoTo { return action.destination }
        return nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if resolvedDestination != nil {
                // Internal Document Destination Preview (Equation, Reference)
                if let img = previewImage {
                    SelectableImageView(image: img)
                        .frame(width: 900, height: 300) // Restore 900 width
                        .padding(8)
                        // A nice subtle border/shadow effect to look like a mini page
                        .background(Color(NSColor.windowBackgroundColor))
                } else {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    .frame(width: 900, height: 300) // Ensure exact same size during loading
                }
            } else {
                Text("Unknown Link")
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .onHover { hovering in
            onHoverStateChanged?(hovering)
        }
        .onAppear {
            generateThumbnail()
        }
    }
    
    private func generateThumbnail() {
        guard let dest = resolvedDestination, let page = dest.page else { return }
        
        nonisolated(unsafe) let safeDest = dest
        nonisolated(unsafe) let safePage = page
        
        DispatchQueue.global(qos: .userInitiated).async {
            let point = safeDest.point
            let pageBounds = safePage.bounds(for: .cropBox)
            
            // 使用完整的页面宽度，保留 PDF 原本的左右页边距，避免文字直接顶满屏幕边缘
            let cropWidth = pageBounds.width
            // 严格匹配 UI 比例 (900x300，即宽高比 3:1)
            let cropHeight = cropWidth * (300.0 / 900.0)
            
            let targetY = point.y
            // 目标点是内容的顶部。为了留出充足的上下文，我们让截取框顶部高出目标点 40 个单位
            var cropRect = NSRect(x: pageBounds.minX, y: targetY + 40 - cropHeight, width: cropWidth, height: cropHeight)
            
            if cropRect.minY < pageBounds.minY { cropRect.origin.y = pageBounds.minY }
            if cropRect.maxX > pageBounds.maxX { cropRect.size.width = pageBounds.maxX - cropRect.minX }
            
            // High-resolution rendering scale factor
            let scale: CGFloat = 2.0
            
            // Get thumbnail of the FULL page at high resolution.
            // PDFPage.thumbnail handles rotation and page transforms perfectly!
            let targetSize = NSSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
            let fullImage = safePage.thumbnail(of: targetSize, for: .cropBox)
            
            // Calculate the exact crop rect in the scaled image coordinates
            let imageCropRect = NSRect(
                x: (cropRect.minX - pageBounds.minX) * scale,
                y: (cropRect.minY - pageBounds.minY) * scale,
                width: cropRect.width * scale,
                height: cropRect.height * scale
            )
            
            // Create the final cropped image
            let croppedImage = NSImage(size: imageCropRect.size)
            croppedImage.lockFocus()
            
            // White background (PDFs are often transparent)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: imageCropRect.size).fill()
            
            // Draw the portion of the full image
            fullImage.draw(at: .zero, from: imageCropRect, operation: .copy, fraction: 1.0)
            
            croppedImage.unlockFocus()
            
            DispatchQueue.main.async {
                self.previewImage = croppedImage
            }
        }
    }
}

#if os(macOS)
import VisionKit

struct SelectableImageView: NSViewRepresentable {
    let image: NSImage
    
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
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
            
            let analyzer = ImageAnalyzer()
            Task {
                if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    do {
                        let configuration = ImageAnalyzer.Configuration([.text])
                        let analysis = try await analyzer.analyze(cgImage, orientation: .up, configuration: configuration)
                        overlay.analysis = analysis
                    } catch {
                        print("VisionKit analysis failed: \(error)")
                    }
                }
            }
        }
        
        return container
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // If image is static, no update needed.
    }
}
#endif
#endif

