import AppKit
import PDFKit
import Combine
import CoreText

// UI/policy boundaries only; worker and cache code come from production files.
typealias PlatformImage = NSImage
extension PDFPage {
    nonisolated func platformThumbnail(of size: CGSize, for box: PDFDisplayBox) -> NSImage { thumbnail(of: size, for: box) }
}
enum MemoryMode { case saving; static var current: Self { .saving }; var policy: any MemoryPolicy { SavingMemoryPolicy() } }
struct SearchMatch: Identifiable, Equatable { let id = UUID(); let boundsArray: [CGRect]; let pageIndex: Int; let context: String }
@main struct RenderHarness {
    @MainActor static func main() async throws {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.textPosition = CGPoint(x: 10, y: 150)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "hello world", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil)]))
        CTLineDraw(line, context); context.endPDFPage(); context.closePDF()
        let doc = PDFDocument()
        for index in 0..<20 { doc.insert(PDFDocument(data: data as Data)!.page(at: 0)!, at: index) }
        let manager = ThumbnailManager(); let search = SearchManager()
        var callbacks = 0
        let subscription = manager.thumbnailUpdateSubject.sink { _ in callbacks += 1 }
        for _ in 0..<100 {
            let page = doc.page(at: 0)!
            manager.generateThumbnail(for: page, at: 0, in: doc, currentDocChecker: { true })
            search.searchQuery = "hello"; search.performSearch(in: doc, pdfView: nil)
            page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .highlight, withProperties: nil))
            doc.removePage(at: 0); doc.insert(page, at: 19)
            manager.clearCache(); search.clear()
        }
        try await Task.sleep(for: .milliseconds(500))
        precondition(manager.getThumbnail(for: 0) == nil && callbacks == 0, "stale thumbnail repopulated cleared cache")
        precondition(search.searchResults.isEmpty)
        let page = doc.page(at: 0)!
        manager.generateThumbnail(for: page, at: 0, in: doc, currentDocChecker: { true })
        manager.updateLiveThumbnail(for: page, at: 0)
        let live = manager.getThumbnail(for: 0)
        precondition(live != nil)
        try await Task.sleep(for: .milliseconds(300))
        precondition(manager.getThumbnail(for: 0) === live, "old queued render replaced live edit")
        manager.handleMemoryPressure()
        manager.prefetchThumbnails(pages: [(0,page)], validRange: 0...0, in: doc, currentDocChecker: { true })
        try await Task.sleep(for: .milliseconds(100)); precondition(manager.getThumbnail(for: 0) == nil)
        search.searchQuery = "hello"; search.performSearch(in: doc, pdfView: nil)
        for _ in 0..<100 where search.isSearching { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!search.searchResults.isEmpty)
        let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("statistics.pdf")
        precondition(doc.write(to: file))
        let counted = await Task.detached { DocumentStatistics.read(url: file) }.value
        precondition(counted?.englishWords == 40)
        let canceled = Task.detached { DocumentStatistics.read(url: file) }; canceled.cancel()
        let cancellationResult = await canceled.value; precondition(cancellationResult == nil)
        withExtendedLifetime(subscription) {}
        print("PASS 100 edit/reorder/search/thumbnail cancel cycles, generation guard, live-update ownership, memory-pressure pause, independent/cancellable statistics")
    }
}
