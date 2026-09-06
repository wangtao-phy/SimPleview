import AppKit
import PDFKit
@testable import SimPleview

@MainActor final class WeakView { weak var value: CustomPDFView?; init(_ value: CustomPDFView) { self.value = value } }
@main struct PDFViewHarness {
    static func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-portable-copy" {
            try verifyPortableCopy(URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var references: [WeakView] = []
        for _ in 0..<20 {
            autoreleasepool {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let view = CustomPDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
                window.contentView = view
                let document = PDFDocument(); let page = PDFPage()
                page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
                document.insert(page, at: 0); view.document = document; view.autoScales = true
                let path = NSBezierPath(); path.move(to: CGPoint(x: 20, y: 20)); path.line(to: CGPoint(x: 120, y: 120))
                view.activeType = .ink
                view.currentDrawingBatchID = "INK-regression"
                view.draftInkPage = page; view.draftInkPaths = [path]
                view.layoutSubtreeIfNeeded(); view.publishRenderSnapshot()
                let bitmap = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                // Exercise the actual app's overridden draw hook using its linked
                // Debug dylib. AppState/startup are not created; no user files open.
                view.draw(page, to: bitmap)
                view.commitDraftInk()
                precondition(page.annotations.first?.paths?.isEmpty == false)
                references.append(WeakView(view))
                view.prepareForDocumentReplacement(); view.document = nil
                window.contentView = nil; window.close()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let alive = references.filter { $0.value != nil }.count
        precondition(alive == 0, "closed CustomPDFView instances retained: \(alive)")
        log("PASS actual Debug app CustomPDFView draw/ink/cleanup, 20 cycles, surviving views=\(alive)")
        try verifyVectorInkAndNoteIcon(alpha: 1)
        try verifyVectorInkAndNoteIcon(alpha: 0.55)
        try verifyPortableAnnotationsAndAutosave()
    }

    @MainActor static func verifyVectorInkAndNoteIcon(alpha: CGFloat) throws {
        let view = CustomPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
        document.insert(page, at: 0); view.document = document
        // 不显示真实窗口；显式指定被测页，让离屏 PDFView 也发布该页快照。
        view.currentDrawingPage = page
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 23, y: 37)); path.line(to: CGPoint(x: 80, y: 148))
        path.line(to: CGPoint(x: 164, y: 54))
        let second = NSBezierPath()
        second.move(to: CGPoint(x: 40, y: 70)); second.line(to: CGPoint(x: 160, y: 70))
        view.activeType = .ink; view.inkColor = NSColor.black.withAlphaComponent(alpha); view.lineWidth = 1.25
        view.currentDrawingBatchID = "B-ink-quality"; view.draftInkPage = page; view.draftInkPaths = [path, second]
        view.layoutSubtreeIfNeeded(); view.publishRenderSnapshot()
        func pixels(_ page: PDFPage, scale: Int) -> Data {
            let size = 200 * scale
            let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            view.draw(page, to: context)
            return Data(bytes: context.data!, count: size * size * 4)
        }
        let scales = [1, 4, 8]
        let draft = scales.map { pixels(page, scale: $0) }
        precondition(draft[0].contains { $0 < 128 }, "quality comparison must contain real ink, not two blank images")
        view.commitDraftInk(); view.activeType = .none; view.publishRenderSnapshot()
        let liveInk = page.annotations[0]
        precondition(!liveInk.shouldDisplay && StandardInk.isScreenHidden(liveInk), "native bitmap layer still enabled")
        // 单独让 PDFKit 画活动页面（不调用自定义矢量钩子），结果必须是空白：
        // 这证明模糊的原生底层已被去掉，而不是用清晰笔迹盖在其上面。
        let nativeImage = page.thumbnail(of: NSSize(width: 200, height: 200), for: .mediaBox)
        let nativeBitmap = NSBitmapImageRep(cgImage: nativeImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let blankPage = PDFPage()
        blankPage.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
        let blankDocument = PDFDocument(); blankDocument.insert(blankPage, at: 0)
        let blankImage = blankPage.thumbnail(of: NSSize(width: 200, height: 200), for: .mediaBox)
        let blankBitmap = NSBitmapImageRep(cgImage: blankImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        for y in 0..<200 { for x in 0..<200 {
            precondition(abs((nativeBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) - (blankBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0)) < 0.01,
                         "native PDFKit bitmap still contains managed ink at \(x),\(y)")
        }}
        let exportedPage = PDFDocument(data: StandardInk.exportData(of: page)!)!.page(at: 0)!
        precondition(exportedPage.annotations[0].shouldDisplay && !StandardInk.isScreenHidden(exportedPage.annotations[0]))
        precondition(!liveInk.shouldDisplay, "export re-enabled live native layer")
        for (index, scale) in scales.enumerated() {
            precondition(pixels(page, scale: scale) == draft[index], "committed ink changed vector rendering at \(scale)x")
        }
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("SimPleview-vector-check-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: saved) }
        try AtomicPDFWriter.write(document, to: saved)
        let reopened = PDFDocument(url: saved)!, reopenedPage = reopened.page(at: 0)!
        precondition(reopenedPage.annotations[0].shouldDisplay && !StandardInk.isScreenHidden(reopenedPage.annotations[0]))
        precondition(!liveInk.shouldDisplay, "save re-enabled live native layer")
        view.prepareForDocumentReplacement(); view.document = reopened
        view.currentDrawingPage = reopenedPage
        view.layoutSubtreeIfNeeded(); view.publishRenderSnapshot()
        precondition(reopenedPage.annotations[0].paths?.count == 2)
        for (index, scale) in scales.enumerated() {
            precondition(pixels(reopenedPage, scale: scale) == draft[index], "reopened ink changed vector rendering at \(scale)x")
        }
        // 保存后的标准批注单独交给 PDFKit 渲染，确认文件并非只剩应用私有叠加层。
        let externalDocument = PDFDocument(url: saved)!
        let standardImage = externalDocument.page(at: 0)!.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox)
        let bitmap = NSBitmapImageRep(cgImage: standardImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let center = bitmap.colorAt(x: 800, y: 1040)?.usingColorSpace(.deviceRGB)
        // 外部 PDFKit 渲染的色彩空间可能不同；半透明线只要求有明确
        // 笔迹对比度。精确透明度比较由上面的应用绘制像素断言负责。
        precondition((center?.redComponent ?? 1) < (alpha < 1 ? 0.9 : 0.5), "standard saved PDF lost vector ink")
        // 紧凑格式不再附带文本坐标，图像导出也必须能从标准路径绘制。
        let pngURL = saved.deletingPathExtension().appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: pngURL) }
        precondition(ImageDocumentManager.exportPDFDocumentToOriginalImageFormat(pdfDocument: reopened, originalURL: pngURL))
        let png = NSBitmapImageRep(data: try Data(contentsOf: pngURL))!
        let inkPixel = png.colorAt(x: 100, y: 130)!.usingColorSpace(.deviceRGB)!
        precondition(inkPixel.alphaComponent > 0.2 && inkPixel.redComponent < 0.9, "compact ink lost image export")
        log("PASS native bitmap layer empty; saved/exported ink visible without changing live state")
        log("PASS draft/committed/reopened app ink pixels identical at 1x, 4x, 8x; multiple strokes, thin line, alpha=\(alpha), standard saved ink visible")

        let upper = PDFAnnotation(bounds: CGRect(x: 20, y: 150, width: 60, height: 12), forType: .highlight, withProperties: nil)
        let lower = PDFAnnotation(bounds: CGRect(x: 20, y: 110, width: 90, height: 12), forType: .highlight, withProperties: nil)
        upper.userName = "B-note-icon"; lower.userName = "B-note-icon"
        reopenedPage.addAnnotation(upper); reopenedPage.addAnnotation(lower)
        view.currentSelectedBatchID = "B-note-icon"; view.publishRenderSnapshot()
        let snapshot = view.renderSnapshot.withLock { $0 }
        let icons = snapshot.pages[ObjectIdentifier(reopenedPage)]!.noteIcons
        precondition(icons.count == 1 && icons[0].rect == CGRect(x: 94, y: 86, width: 20, height: 20))
        let iconBitmap = NSBitmapImageRep(cgImage: icons[0].image)
        var transparent = false, visible = false
        for y in 0..<iconBitmap.pixelsHigh { for x in 0..<iconBitmap.pixelsWide {
            let alpha = iconBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
            transparent = transparent || alpha == 0; visible = visible || alpha > 0
        }}
        precondition(transparent && visible, "note icon lost transparent symbol rendering")
        view.currentSelectedBatchID = nil
        let pageIdentity = ObjectIdentifier(reopenedPage)
        precondition(view.renderSnapshot.withLock { $0.pages[pageIdentity]!.noteIcons.isEmpty })
        view.prepareForDocumentReplacement(); view.document = nil
        log("PASS one transparent note.text icon at lowest selected annotation, original hit-target geometry, deselection removes icon")
    }

    @MainActor static func verifyPortableCopy(_ url: URL) throws {
        // 在全新进程里只打开复制后的 PDF，不加载 AppState、偏好或本机数据库。
        let document = PDFDocument(url: url)!
        precondition(document.pageCount == 10)
        let all = (0..<10).flatMap { document.page(at: $0)!.annotations }
        precondition(all.count == 101)
        for index in 0..<100 {
            let annotation = all.first { $0.userName == "B-portable-\(index)" }!
            precondition(annotation.shouldDisplay && annotation.simPleNote == "跨设备笔记 \(index)")
        }
        let ink = all.first { $0.type == "Ink" }!
        precondition(ink.shouldDisplay && ink.paths?.count == 1 && !StandardInk.isScreenHidden(ink))
        precondition(ink.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/SimPlePath")) as? String == "")
        precondition(ink.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/SimPlePath1")) == nil)
        StandardInk.prepareForScreen(in: document)
        precondition(StandardInk.isScreenHidden(ink) && StandardInk.pagePaths(of: ink)[0].elementCount == 10000)
        log("PASS independent process: copied PDF retains 100 notes, 10,000-point vector ink")
    }

    @MainActor static func verifyPortableAnnotationsAndAutosave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SimPleview-portable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("original.pdf")
        let copiedURL = directory.appendingPathComponent("other-computer.pdf")
        let document = PDFDocument()
        for index in 0..<10 {
            let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
            document.insert(page, at: index)
        }
        try AtomicPDFWriter.write(document, to: originalURL)
        let baseSize = try Data(contentsOf: originalURL).count
        for index in 0..<100 {
            let types: [PDFAnnotationSubtype] = [.highlight, .underline, .strikeOut]
            let annotation = PDFAnnotation(bounds: CGRect(x: 30, y: 30 + (index % 10) * 25, width: 200, height: 15), forType: types[index % 3], withProperties: nil)
            annotation.userName = "B-portable-\(index)"; annotation.simPleNote = "跨设备笔记 \(index)"
            annotation.color = .yellow
            document.page(at: index / 10)!.addAnnotation(annotation)
        }
        let page = document.page(at: 0)!
        let view = CustomPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.document = document; view.currentDrawingPage = page
        let path = NSBezierPath()
        for index in 0..<10000 {
            let point = CGPoint(x: 40 + Double(index) / 25, y: 400 + sin(Double(index) / 40) * 60)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        view.activeType = .ink; view.inkColor = .black
        view.currentDrawingBatchID = "B-portable-ink"; view.draftInkPage = page; view.draftInkPaths = [path]
        view.commitDraftInk(); view.activeType = .none
        view.currentSelectedBatchID = "B-portable-0"; view.publishRenderSnapshot()
        let pageID = ObjectIdentifier(page)
        let visible = view.renderSnapshot.withLock { $0 }.pages[pageID]!
        precondition(!visible.strokes.isEmpty && visible.noteIcons.count == 1)
        let originalFlags = page.annotations.map { ($0.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0 }
        view.setAnnotationsVisible(false)
        let hidden = view.renderSnapshot.withLock { $0 }.pages[pageID]!
        precondition(hidden.strokes.isEmpty && hidden.noteIcons.isEmpty)
        precondition(page.annotations.count == 11 && (0..<10).allSatisfy { !document.page(at: $0)!.displaysAnnotations })
        let native = page.thumbnail(of: NSSize(width: 600, height: 800), for: .mediaBox)
        let bitmap = NSBitmapImageRep(cgImage: native.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        for y in stride(from: 0, to: 800, by: 5) { for x in stride(from: 0, to: 600, by: 5) {
            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            precondition(min(color.redComponent, color.greenComponent, color.blueComponent) > 0.98, "hidden native annotation remains")
        }}
        try AtomicPDFWriter.write(document, to: originalURL)
        let size = try Data(contentsOf: originalURL).count
        precondition(size - baseSize < 650_000, "annotation data unexpectedly inflated: \(size - baseSize)")
        try FileManager.default.copyItem(at: originalURL, to: copiedURL)
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--verify-portable-copy", copiedURL.path]
        try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
        // 重复保存不得不断追加一套标注或整个页面位图。
        try AtomicPDFWriter.write(document, to: originalURL)
        let repeatedSize = try Data(contentsOf: originalURL).count
        precondition(abs(repeatedSize - size) < 1024)
        view.setAnnotationsVisible(true)
        precondition(page.annotations.map { ($0.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0 } == originalFlags)
        precondition(!view.renderSnapshot.withLock { $0.pages[pageID]!.strokes.isEmpty })
        log("PASS hide/show native marks + vector ink + note icon; saving while hidden preserves annotations")
        log("SIZE base=\(baseSize) bytes; 100 notes + 10,000-point ink=\(size) bytes; repeated save=\(repeatedSize) bytes")
        view.prepareForDocumentReplacement(); view.document = nil

        let draftDocument = PDFDocument(); let draftPage = PDFPage()
        draftPage.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox); draftDocument.insert(draftPage, at: 0)
        let draftURL = directory.appendingPathComponent("draft.pdf")
        try AtomicPDFWriter.write(draftDocument, to: draftURL)
        let manager = DocumentManager(); manager.fileURL = draftURL
        let draftView = CustomPDFView(); draftView.document = draftDocument
        draftView.activeType = .ink; draftView.currentDrawingBatchID = "B-autosave-draft"
        let line = NSBezierPath(); line.move(to: CGPoint(x: 20, y: 20)); line.line(to: CGPoint(x: 100, y: 100))
        draftView.draftInkPage = draftPage; draftView.draftInkPaths = [line, line]
        draftView.onSaveRequired = { manager.isDirty = true }
        manager.isDirty = true
        precondition(manager.save(pdfView: draftView, automatically: true, documentToSave: draftView.makeAutosaveDocument()!))
        precondition(draftPage.annotations.isEmpty && draftView.draftInkPaths.count == 2)
        precondition(PDFDocument(url: draftURL)!.page(at: 0)!.annotations[0].paths?.count == 2)
        precondition(draftView.undoDraftInk() && manager.isDirty)
        precondition(manager.save(pdfView: draftView, automatically: true, documentToSave: draftView.makeAutosaveDocument()!))
        precondition(PDFDocument(url: draftURL)!.page(at: 0)!.annotations[0].paths?.count == 1)
        precondition(draftView.undoDraftInk() && manager.isDirty)
        precondition(manager.save(pdfView: draftView, automatically: true, documentToSave: draftView.makeAutosaveDocument()!))
        precondition(PDFDocument(url: draftURL)!.page(at: 0)!.annotations.isEmpty)
        // 模拟 iCloud/外部程序替换文件，自动保存不能覆盖新字节。
        let external = PDFDocument(); external.insert(PDFPage(), at: 0)
        try AtomicPDFWriter.write(external, to: draftURL)
        let externalBytes = try Data(contentsOf: draftURL)
        manager.isDirty = true
        precondition(!manager.save(pdfView: draftView, automatically: true))
        precondition(manager.isDirty && manager.saveIssue != nil)
        let bytesAfterConflict = try Data(contentsOf: draftURL)
        precondition(bytesAfterConflict == externalBytes)
        draftView.prepareForDocumentReplacement(); draftView.document = nil; manager.closeAll()
        log("PASS autosave preserves draft editing, persists single-stroke undo/deletion; external replacement blocks autosave without losing either version")
    }

}
