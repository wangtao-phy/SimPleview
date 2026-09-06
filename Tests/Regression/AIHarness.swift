import Foundation
import PDFKit
import ImageIO
import os

// All persistence is isolated; fake API keys never reach a network service.
enum ReviewDefaults { static let standard = UserDefaults(suiteName: "SimPleview.AIRegression." + UUID().uuidString)! }
class TestPDFView: PDFView { func commitDraftInk() {} }
class AppState { var pdfView = TestPDFView(); var editRevision: UInt = 0; var isClosed = false; var fileName = "test.pdf" }
class DirectoryManager {
    static let shared = DirectoryManager()
    let appRootDirectory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AIData")
}
enum APIKeyStore {
    static func load(account: String = "default") throws -> String { "fake-" + account }
    static func save(_ key: String, account: String = "default") throws {}
}
@MainActor final class RecordingTransport: AIChatTransport {
    var routes: [AIRoute] = []
    var pageBatches: [[Int]] = []
    var active = 0, maximumActive = 0
    var delay = 0.04
    var fail = false
    func stream(route: AIRoute, apiKey: String, messages: [ChatMessage], images: [AIImageInput],
                onUpdate: @escaping @MainActor @Sendable (AIStreamUpdate) -> Void) async throws {
        active += 1; maximumActive = max(maximumActive, active); defer { active -= 1 }
        routes.append(route); pageBatches.append(images.map(\.pageNumber))
        // Assert the production wire builder, rather than just the picker value.
        let request = try AIChatService.makeRequest(route: route, apiKey: apiKey, messages: messages, images: images)
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(json["model"] as? String == route.model.modelID && json["n"] as? Int == 1)
        precondition(request.url!.absoluteString == route.endpoint.baseURL + "/chat/completions")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-" + route.endpoint.keyAccount)
        if !images.isEmpty {
            let content = (json["messages"] as! [[String: Any]]).last!["content"] as! [[String: Any]]
            precondition(content.filter { $0["type"] as? String == "image_url" }.count == images.count)
        }
        onUpdate(.init(content: "第一句。尚未结束", responseModel: route.model.modelID))
        // Ignore cancellation intentionally, to test late callbacks and lease lifetime.
        await withCheckedContinuation { continuation in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { continuation.resume() } }
        if fail { throw URLError(.timedOut) }
        onUpdate(.init(content: "第一句。尚未结束的第二句。", responseModel: route.model.modelID, complete: true))
    }
}
@MainActor final class FakePDFSource: PDFVisionSource {
    let pageCount: Int
    let fileName = "synthetic.pdf"
    let data: Data
    var invalid = false
    var requestedIndices: [Int] = []
    init(pages: Int) {
        pageCount = pages
        let doc = PDFDocument(); let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
        doc.insert(page, at: 0); data = doc.dataRepresentation()!
    }
    func verify() throws { if invalid { throw AIConfigurationError.message("PDF changed") } }
    func pageData(at index: Int) throws -> Data { try verify(); precondition((0..<pageCount).contains(index)); requestedIndices.append(index); return data }
}
@main struct AIHarness {
    @MainActor static func settle(_ gate: AIRequestGate) async throws {
        for _ in 0..<1000 {
            if !gate.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("AI task did not release its generation lease")
    }
    @MainActor static func main() async throws {
        let store = AIConfigurationStore(defaults: ReviewDefaults.standard)
        precondition(store.selectedRoute?.endpoint.baseURL == "https://api.openai.com/v1")
        precondition(store.selectedRoute?.endpoint.keyAccount == "default", "legacy key account migrated to another provider")
        var a = AIEndpointConfiguration.deepSeek(); a.name = "API A"; a.baseURL = "https://a.invalid/v1"; a.keyAccount = "A"
        var b = AIEndpointConfiguration.deepSeek(); b.name = "API B"; b.baseURL = "https://b.invalid/v1"; b.keyAccount = "B"
        try store.save(a); try store.save(b)
        var duplicate = AIEndpointConfiguration.deepSeek(); duplicate.name = a.name
        do { try store.save(duplicate); fatalError("ambiguous API labels accepted") } catch {}
        let restored = AIConfigurationStore(defaults: ReviewDefaults.standard)
        precondition(restored.routes.contains { $0.id == a.models[0].id && $0.endpoint.keyAccount == "A" })
        store.select(a.models[0].id)
        let transport = RecordingTransport(), gate = AIRequestGate()
        let manager = ConversationManager.shared
        func makeVM(_ document: String) -> AIChatViewModel {
            let vm = AIChatViewModel(configuration: store, transport: transport, conversations: manager, gate: gate, keyLoader: { "fake-" + $0 })
            vm.configure(with: document); return vm
        }
        let vm = makeVM("first"), other = makeVM("other")
        vm.inputText = "hello"; vm.sendMessage(appState: nil)
        try await Task.sleep(for: .milliseconds(10))
        precondition(vm.messages.last?.content == "第一句。", "unfinished sentence was displayed")
        store.select(b.models[1].id) // Picker changes cannot change the in-flight request.
        vm.inputText = "duplicate"; vm.sendMessage(appState: nil)
        other.inputText = "parallel"; other.sendMessage(appState: nil)
        precondition(vm.messages.count == 2 && other.messages.isEmpty)
        vm.pauseGeneration()
        precondition(gate.isBusy && vm.messages.last?.generationState == "paused")
        precondition(vm.messages.last?.content == "第一句。尚未结束", "pause lost buffered text")
        try await settle(gate)
        precondition(vm.messages.last?.generationState == "paused")
        vm.resumeAnswer(); try await settle(gate)
        precondition(transport.routes.last?.model.modelID == a.models[0].modelID && transport.routes.last?.endpoint.id == a.id)
        precondition(vm.messages.last?.generationState == "completed")
        vm.inputText = "next"; vm.sendMessage(appState: nil); try await settle(gate)
        precondition(transport.routes.last?.endpoint.id == b.id && transport.routes.last?.model.modelID == "deepseek-v4-pro")
        precondition(transport.maximumActive == 1)
        print("PASS exact API/model/key wire routing, immutable in-flight route, buffered sentences, pause/late callback, original-route resume, cross-window serialization")

        for failure in [false, true] {
            transport.fail = failure
            vm.inputText = "switch"; vm.sendMessage(appState: nil)
            try await Task.sleep(for: .milliseconds(10)); vm.createNewSession()
            try await settle(gate); precondition(vm.messages.isEmpty)
        }
        transport.fail = false
        var temporary: AIChatViewModel? = makeVM("temporary")
        temporary!.inputText = "release"; temporary!.sendMessage(appState: nil)
        try await Task.sleep(for: .milliseconds(10)); weak var weakVM = temporary; temporary = nil
        precondition(weakVM == nil); try await settle(gate)
        print("PASS session switch during delayed reply/error and ViewModel release while generating")

        let route = AIRoute(endpoint: a, model: a.models[0])
        var parser = AIStreamAccumulator(route: route)
        func event(model: String, content: String, index: Int = 0) -> String {
            let data = try! JSONSerialization.data(withJSONObject: ["model": model, "choices": [["index": index, "delta": ["content": content]]]])
            return "data:" + String(decoding: data, as: UTF8.self)
        }
        do { _ = try parser.consume(event(model: "deepseek-v4-pro", content: "wrong")); fatalError("model mismatch accepted") } catch {}
        precondition(parser.update.content.isEmpty)
        _ = try parser.consume(event(model: "deepseek-v4-flash", content: "<thi"))
        _ = try parser.consume(event(model: "deepseek-v4-flash", content: "nk>reason</thi"))
        _ = try parser.consume(event(model: "deepseek-v4-flash", content: "nk>answer。"))
        _ = try parser.consume(event(model: "deepseek-v4-flash", content: "parallel", index: 1))
        precondition(parser.update.content == "answer。" && parser.update.thinking == "reason")
        _ = try parser.consume("data: [DONE]"); precondition(parser.done)
        print("PASS server model mismatch rejection, split think tags, exactly one choice, SSE data syntax")

        store.select(a.models[2].id)
        let pdfVM = makeVM("pdf"), source = FakePDFSource(pages: 5)
        let offset = transport.pageBatches.count
        try pdfVM.readEntirePDF(source: source); try await settle(gate)
        let pages = transport.pageBatches.dropFirst(offset).filter { !$0.isEmpty }
        precondition(Array(pages) == [[1,2],[3,4],[5]])
        precondition(pdfVM.messages.last?.pdfProgress?.completedPages == 5 && pdfVM.messages.last?.generationState == "completed")
        precondition(pdfVM.messages.last?.content.contains("全文总结") == true && pdfVM.messages.last?.pdfSummary?.isEmpty == false)
        let jpeg = try await PDFVisionRenderer.image(data: source.data, pageNumber: 1)
        let image = CGImageSourceCreateWithData(jpeg.jpeg as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
        precondition((properties[kCGImagePropertyPixelWidth] as! Int) <= 1536 && (properties[kCGImagePropertyPixelHeight] as! Int) <= 1536)
        print("PASS all PDF pages serialized in order 1–5, actual JPEG rendering, vision wire blocks, progress and full-document summary")

        let pausedPDF = makeVM("pdf-pause")
        transport.delay = 0.2
        try pausedPDF.readEntirePDF(source: FakePDFSource(pages: 3))
        for _ in 0..<100 where transport.active == 0 { try await Task.sleep(for: .milliseconds(10)) }
        pausedPDF.pauseGeneration(); try await settle(gate)
        precondition(pausedPDF.messages.last?.pdfProgress?.completedPages == 0)
        let resumedAt = transport.pageBatches.count
        transport.delay = 0.01; pausedPDF.resumeAnswer(); try await settle(gate)
        precondition(transport.pageBatches[resumedAt] == [1,2])
        precondition(pausedPDF.messages.last?.pdfProgress?.completedPages == 3)
        let changedPDF = makeVM("pdf-change"), changedSource = FakePDFSource(pages: 2)
        try changedPDF.readEntirePDF(source: changedSource); changedSource.invalid = true
        try await settle(gate); precondition(changedPDF.messages.last?.generationState == "failed")
        precondition(transport.maximumActive == 1)
        print("PASS PDF pause retries incomplete batch, changed document fails explicitly, no parallel batch/summary calls")

        let pageVM = makeVM("current-page"), pageSource = FakePDFSource(pages: 9)
        let pageOffset = transport.pageBatches.count
        try pageVM.readCurrentPDFPage(source: pageSource, pageIndex: 6); try await settle(gate)
        precondition(pageSource.requestedIndices == [6], "single-page action read another page")
        precondition(Array(transport.pageBatches.dropFirst(pageOffset)) == [[7]], "single-page action made extra requests")
        precondition(pageVM.messages.last?.pdfProgress?.pageNumber == 7 && pageVM.messages.last?.pdfProgress?.completedPages == 1)
        precondition(pageVM.messages.last?.generationState == "completed" && pageVM.messages.last?.pdfSummary == nil)
        let invalidPageVM = makeVM("invalid-page")
        for index in [-1, 9] {
            do { try invalidPageVM.readCurrentPDFPage(source: pageSource, pageIndex: index); fatalError("invalid page accepted") } catch {}
        }
        precondition(invalidPageVM.messages.isEmpty)
        let pausedPage = makeVM("paused-page"), pausedPageSource = FakePDFSource(pages: 9)
        transport.delay = 0.2
        try pausedPage.readCurrentPDFPage(source: pausedPageSource, pageIndex: 4)
        for _ in 0..<100 where transport.active == 0 { try await Task.sleep(for: .milliseconds(10)) }
        pausedPage.pauseGeneration(); try await settle(gate)
        store.select(b.models[2].id)
        transport.delay = 0.01
        pausedPage.resumeAnswer(); try await settle(gate)
        precondition(pausedPageSource.requestedIndices == [4, 4])
        precondition(transport.pageBatches.last == [5] && transport.routes.last?.endpoint.id == a.id)
        precondition(pausedPage.messages.last?.generationState == "completed" && transport.maximumActive == 1)
        print("PASS current-page reads only original page with original page number, no summary request, invalid-page rejection, original-page/route resume")

        let networkConfig = URLSessionConfiguration.ephemeral
        networkConfig.protocolClasses = [AIStubURLProtocol.self]
        let networkSession = URLSession(configuration: networkConfig)
        defer { networkSession.invalidateAndCancel() }
        let actualService = AIChatService(session: networkSession)
        var updates: [AIStreamUpdate] = []
        let response1 = event(model: "deepseek-v4-flash", content: "value <") + "\n\ndata: [DONE]\n\n"
        AIStubURLProtocol.responseBody.withLock { $0 = response1 }
        try await actualService.stream(route: route, apiKey: "fake-A", messages: [.init(role: "user", content: "hello")]) { updates.append($0) }
        precondition(updates.last?.complete == true && updates.last?.content == "value <", "stream tail was dropped")
        updates = []
        let response2 = event(model: "deepseek-v4-pro", content: "wrong model") + "\n\ndata: [DONE]\n\n"
        AIStubURLProtocol.responseBody.withLock { $0 = response2 }
        do {
            try await actualService.stream(route: route, apiKey: "fake-A", messages: [.init(role: "user", content: "hello")]) { updates.append($0) }
            fatalError("network service accepted Pro for Flash")
        } catch {}
        precondition(updates.isEmpty)
        let response3 = event(model: "deepseek-v4-flash", content: "partial.") + "\n\n"
        AIStubURLProtocol.responseBody.withLock { $0 = response3 }
        do {
            try await actualService.stream(route: route, apiKey: "fake-A", messages: [.init(role: "user", content: "hello")]) { updates.append($0) }
            fatalError("truncated stream reported success")
        } catch {}
        precondition(updates.last?.content == "partial." && updates.last?.complete == false)
        AIStubURLProtocol.responseBody.withLock { $0 = "data: {\"error\":{\"message\":\"echo fake-A\"}}\n\n" }
        do {
            try await actualService.stream(route: route, apiKey: "fake-A", messages: [.init(role: "user", content: "hello")]) { _ in }
            fatalError("API error ignored")
        } catch { precondition(!error.localizedDescription.contains("fake-A"), "key leaked into persisted error") }
        print("PASS unique API labels, stable configuration IDs, and gateway-error credential redaction")
        print("PASS production URLSession/SSE transport, model mismatch before display, tail flush and interrupted-stream failure (intercepted network)")

        // Preserve the previous persistence and context regression coverage.
        let originals = (0..<20).map { ChatMessage(role: "user", content: $0 < 16 ? String(repeating: "中_text_", count: 700) : "recent") }
        var requests = 0
        let prepared = try await AIContextBuilder.prepare(originals, budget: 4096) { batch in
            precondition(AIContextBuilder.cost(batch) <= 4096); requests += 1; return "safe summary"
        }
        precondition(requests > 0 && AIContextBuilder.cost(prepared) <= 4096 && originals.count == 20)
        let session = ConversationSession(id: UUID(), documentID: "persist", createdAt: Date(), updatedAt: Date(), title: "test", messages: originals)
        manager.saveSession(session); precondition(manager.flush())
        let loaded = try manager.loadSession(id: session.id, documentID: "persist"); precondition(loaded.messages.count == originals.count)
        precondition(manager.loadSessions(for: "persist").allSatisfy { $0.messages.isEmpty })
        let blocked = DirectoryManager.shared.appRootDirectory.appendingPathComponent("Conversation/blocked")
        try Data("blocked".utf8).write(to: blocked)
        var pending = session; pending.documentID = "blocked"
        manager.saveSession(pending); precondition(!manager.flush())
        try FileManager.default.removeItem(at: blocked); precondition(manager.flush())
        let recovered = try manager.loadSession(id: pending.id, documentID: "blocked"); precondition(recovered.messages.count == originals.count)
        print("PASS retained original context, metadata-only sessions, atomic persistence and failed-write retry")
    }
}

// Intercept the production URLSession transport; no DNS/network access occurs.
nonisolated final class AIStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let responseBody = OSAllocatedUnfairLock(initialState: "")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.withLock { $0 }.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
