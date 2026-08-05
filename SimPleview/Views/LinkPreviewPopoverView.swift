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
    
    var a: CGFloat {
        resolvedDestination?.page?.bounds(for: .cropBox).width ?? 800.0
    }
    
    var innerWidth: CGFloat { a * 0.8 }
    // cropHeight was a / 3.0, so innerHeight is (a / 3.0) * 0.8
    var innerHeight: CGFloat { (a / 3.0) * 0.8 }
    
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
            
            let cropWidth = pageBounds.width
            let cropHeight = cropWidth / 3.0
            let targetY = point.y
            
            var cropRect = NSRect(
                x: pageBounds.minX, 
                y: targetY - cropHeight + 40, 
                width: cropWidth, 
                height: cropHeight
            )
            
            if cropRect.minY < pageBounds.minY { cropRect.origin.y = pageBounds.minY }
            
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

