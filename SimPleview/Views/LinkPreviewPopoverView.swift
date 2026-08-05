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
            
            // 1. Calculate visual size based on rotation
            let rotation = safePage.rotation
            let visualSize: NSSize
            if rotation == 90 || rotation == 270 {
                visualSize = NSSize(width: pageBounds.height, height: pageBounds.width)
            } else {
                visualSize = pageBounds.size
            }
            
            // 2. Map target point to visual coordinates (bottom-left origin)
            let nx = point.x - pageBounds.minX
            let ny = point.y - pageBounds.minY
            let w = pageBounds.width
            let h = pageBounds.height
            
            let visualY: CGFloat
            switch rotation {
            case 90:  visualY = w - nx
            case 180: visualY = h - ny
            case 270: visualY = nx
            default:  visualY = ny
            }
            
            // 3. Define the visual crop rect (3:1 aspect ratio)
            let cropWidth = visualSize.width
            let cropHeight = cropWidth * (300.0 / 900.0)
            
            // Target point should be near the top of the crop (40 units padding)
            var cropRect = NSRect(x: 0, y: visualY + 40 - cropHeight, width: cropWidth, height: cropHeight)
            if cropRect.minY < 0 { cropRect.origin.y = 0 }
            
            // 4. Generate full high-res visual thumbnail
            let scale: CGFloat = 2.0
            let targetSize = NSSize(width: visualSize.width * scale, height: visualSize.height * scale)
            let fullImage = safePage.thumbnail(of: targetSize, for: .cropBox)
            
            // 5. Crop the exact region
            let imageCropRect = NSRect(
                x: cropRect.minX * scale,
                y: cropRect.minY * scale,
                width: cropRect.width * scale,
                height: cropRect.height * scale
            )
            
            let croppedImage = NSImage(size: imageCropRect.size)
            croppedImage.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: imageCropRect.size).fill()
            // Using .sourceOver to properly blend the PDF over the white background in case of transparency
            fullImage.draw(at: .zero, from: imageCropRect, operation: .sourceOver, fraction: 1.0)
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

