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
                        .frame(width: 900, height: 200) // Ensure exact frame to prevent VisionKit from squishing
                        .padding(8)
                        // A nice subtle border/shadow effect to look like a mini page
                        .background(Color(NSColor.windowBackgroundColor))
                } else {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    .frame(width: 900, height: 350) // Match the width of the final image to ensure NSPopover calculates screen bounds correctly BEFORE showing
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
            
            // Formulas usually span the center, but the link destination is often at the equation number on the right.
            // Cut off standard page margins (e.g., 50 points) to zoom in more on the actual content, making it larger in the UI.
            let margin: CGFloat = 50
            let startX = pageBounds.minX + margin
            let cropWidth = max(pageBounds.width - margin * 2, 300)
            
            // Set height to 200 to capture enough context without getting too tall.
            let cropHeight: CGFloat = 200
            
            let targetY = point.y
            // Start the crop box slightly above the destination point (20 pts) and go down.
            var cropRect = NSRect(x: startX, y: targetY - cropHeight + 20, width: cropWidth, height: cropHeight)
            
            if cropRect.minY < pageBounds.minY { cropRect.origin.y = pageBounds.minY }
            if cropRect.maxX > pageBounds.maxX { cropRect.size.width = pageBounds.maxX - cropRect.minX }
            
            // High-resolution rendering scale factor
            let scale: CGFloat = 2.0
            
            let pixelSize = NSSize(width: cropRect.width * scale, height: cropRect.height * scale)
            let image = NSImage(size: pixelSize)
            
            image.lockFocus()
            guard let context = NSGraphicsContext.current?.cgContext else {
                image.unlockFocus()
                return
            }
            
            // White background (PDFs are often transparent)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: pixelSize).fill()
            
            // Apply scale
            context.scaleBy(x: scale, y: scale)
            // Shift context so cropRect.origin aligns to (0,0)
            context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
            
            safePage.draw(with: .cropBox, to: context)
            
            image.unlockFocus()
            
            DispatchQueue.main.async {
                self.previewImage = image
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

