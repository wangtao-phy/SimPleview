import AppKit
import PDFKit
import Darwin

@main struct CoreHarness {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let target = root.appendingPathComponent("monitor.txt")
        try Data("test".utf8).write(to: target)
        func countFDs() -> Int { (0..<2048).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
        func cycles(_ count: Int) {
            for _ in 0..<count { autoreleasepool { let monitor = FileMonitor(url: target); monitor.stop(); monitor.stop() } }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        cycles(1); let baseline = countFDs(); cycles(100)
        precondition(countFDs() == baseline, "FileMonitor leaked descriptors")
        print("PASS FileMonitor 100 stop/release cycles; FD baseline=\(baseline), final=\(countFDs())")

        let doc = PDFDocument(); let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
        doc.insert(page, at: 0)
        let ink = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 100, height: 100), forType: .ink, withProperties: nil)
        ink.color = .black; let border = PDFBorder(); border.lineWidth = 4; ink.border = border
        let path = NSBezierPath(); path.move(to: CGPoint(x: 30, y: 40)); path.line(to: CGPoint(x: 110, y: 110))
        StandardInk.add(pagePaths: [path], to: ink); page.addAnnotation(ink)
        let saved = root.appendingPathComponent("ink.pdf")
        try AtomicPDFWriter.write(doc, to: saved)
        let reopened = PDFDocument(url: saved)!
        precondition(reopened.page(at: 0)!.annotations.first!.paths?.isEmpty == false)
        let bitmap = reopened.page(at: 0)!.thumbnail(of: NSSize(width: 200, height: 200), for: .mediaBox)
        let rep = NSBitmapImageRep(cgImage: bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        var dark = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent < 0.5 { dark += 1 }
        }}
        precondition(dark > 100, "standard PDF renderer lost ink")
        let original = try Data(contentsOf: saved)
        do { try AtomicPDFWriter.write(doc, to: root.appendingPathComponent("missing/ink.pdf")); fatalError("expected save failure") } catch {}
        let afterFailure = try Data(contentsOf: saved)
        precondition(afterFailure == original)
        let legacy = PDFAnnotation(bounds: ink.bounds, forType: .ink, withProperties: nil)
        legacy.setValue("M,30,40;L,110,110;", forAnnotationKey: PDFAnnotationKey(rawValue: "/SimPlePath"))
        page.addAnnotation(legacy)
        precondition(StandardInk.migrate(in: doc)); precondition(!StandardInk.migrate(in: doc))
        print("PASS standard ink save/reopen/render (\(dark) dark pixels), legacy migration idempotence, failed save preserves original")

        let store = ThumbnailStore(byteLimit: 300_000); let owners = (0..<5).map { _ in UUID() }
        let image = NSImage(cgImage: rep.cgImage!, size: .zero)
        // Choose a budget large enough to retain one image per owner.
        let bytes = rep.cgImage!.bytesPerRow * rep.pixelsHigh
        let cache = ThumbnailStore(byteLimit: bytes * 6)
        for owner in owners { for index in 0..<100 { cache.insert(image, owner: owner, page: index); precondition(cache.totalBytes <= cache.byteLimit) } }
        for owner in owners { cache.remove(owner: owner) }; precondition(cache.totalBytes == 0)
        store.insert(image, owner: owners[0], page: 0); precondition(store.totalBytes <= store.byteLimit)
        precondition(ValidatedLimits.seconds("inf") == 15 && ValidatedLimits.seconds("NaN") == 15)
        precondition(ValidatedLimits.seconds("1e300") == 86400)
        precondition(ValidatedLimits.count(.infinity, fallback: 50, range: 1...500) == 50)
        precondition(DocumentIdentity.id(for: URL(fileURLWithPath: "/a/paper.pdf")) != DocumentIdentity.id(for: URL(fileURLWithPath: "/b/paper.pdf")))
        let hostile = "/tmp/a$(touch OWNED);`echo BAD`.tex"
        precondition(SyncTeXLauncher.sourceArguments(path: hostile, line: 12) == ["-g", hostile + ":12"])
        print("PASS thumbnail byte budget across 5 owners, numeric bounds, document identity, literal SyncTeX arguments")
    }
}
