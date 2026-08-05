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
                // Internal Document Destination Preview
                if let img = previewImage {
                    SelectableImageView(image: img)
                        // The image itself now contains the margins, so it fills the entire 800x320 popover
                        .frame(width: 800, height: 320)
                } else {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    .frame(width: 800, height: 320)
                }
            } else {
                Text("Unknown Link")
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .frame(width: 800, height: 320)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
        .onHover { hovering in
            onHoverStateChanged?(hovering)
        }
        .onAppear {
            generateThumbnail()
        }
    }
    
    /// Generates a perfectly proportioned crop of the PDF destination.
    /// The logic relies on maintaining the original page width and calculating height strictly, 
    /// ensuring the Y-axis location is exact without arbitrary scaling.
    private func generateThumbnail() {
        guard let dest = resolvedDestination, let page = dest.page else { return }
        
        nonisolated(unsafe) let safeDest = dest
        nonisolated(unsafe) let safePage = page
        
        DispatchQueue.global(qos: .userInitiated).async {
            let point = safeDest.point
            let pageBounds = safePage.bounds(for: .cropBox)
            
            // 1. Expand the cropWidth by 100 points to create a guaranteed 50px margin on both sides INSIDE the image.
            let cropWidth = pageBounds.width + 100
            // 2. Calculate cropHeight to perfectly match the 800x320 UI frame ratio, preventing any VisionKit squishing.
            let cropHeight = cropWidth * (320.0 / 800.0)
            
            // 3. The Y-coordinate provided by the destination is positioned 40 points 
            // below the top edge of our crop box, ensuring the target text is visible.
            let targetY = point.y
            
            var cropRect = NSRect(
                x: pageBounds.minX - 50, // Shift X left by 50 to center the PDF inside the wider crop box
                y: targetY - cropHeight + 40,
                width: cropWidth,
                height: cropHeight
            )
            
            // Prevent cropping outside the bottom edge of the page
            if cropRect.minY < pageBounds.minY { 
                cropRect.origin.y = pageBounds.minY 
            }
            
            // 4. Render at @2x scale for Retina displays
            let scale: CGFloat = 2.0
            
            let pixelSize = NSSize(width: cropRect.width * scale, height: cropRect.height * scale)
            let image = NSImage(size: pixelSize)
            
            image.lockFocus()
            guard let context = NSGraphicsContext.current?.cgContext else {
                image.unlockFocus()
                return
            }
            
            // 4. Paint a white background because some PDFs are transparent
            NSColor.white.setFill()
            NSRect(origin: .zero, size: pixelSize).fill()
            
            // 5. Transform context to draw the cropped region filling the image
            context.scaleBy(x: scale, y: scale)
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

