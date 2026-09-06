import AppKit
import os

enum ReviewDefaults { static let standard = UserDefaults(suiteName: "SimPleview.RecordsRegression." + UUID().uuidString)! }
class DirectoryManager {
    static let shared = DirectoryManager()
    func getDirectory(for name: String) -> URL {
        URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("RecordsData")
    }
}
class AppState { func updateReadingTracking() {} }
class AppWindowController: NSWindowController { var appState: AppState? }
extension Logger { static let view = Logger(subsystem: "SimPleview.Regression", category: "records") }
@main struct RecordsHarness {
    @MainActor static func main() throws {
        let tracker = ReadingTracker.shared
        var record = DocumentRecord(documentID: "record-a", documentTitle: "A")
        record.articleSummary = "must survive failures"
        record.authors = [AuthorInfo(firstName: "Test", lastName: "Author", bio: "retained biography")]
        tracker.updateRecord(record)
        precondition(tracker.saveAllRecords(sync: true))
        precondition(GlobalAuthorManager.shared.saveAuthors(sync: true))
        let blocked = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("blocked-record-directory")
        try Data("blocked".utf8).write(to: blocked)
        tracker.customDirectoryURL = blocked
        tracker.updateRecord(record)
        tracker.saveAllRecords()
        precondition(!tracker.saveAllRecords(sync: true))
        precondition(!GlobalAuthorManager.shared.saveAuthors(sync: true))
        tracker.customDirectoryURL = nil
        precondition(tracker.customDirectoryURL == blocked, "directory switch discarded failed records")
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        precondition(tracker.saveAllRecords(sync: true))
        precondition(GlobalAuthorManager.shared.saveAuthors(sync: true))
        let persisted = try JSONDecoder().decode(DocumentRecord.self, from: Data(contentsOf: blocked.appendingPathComponent("record-a.json")))
        precondition(persisted.articleSummary == record.articleSummary)
        let authors = try JSONDecoder().decode([String: GlobalAuthor].self, from: Data(contentsOf: blocked.appendingPathComponent("GlobalAuthors.json")))
        precondition(authors["Author Test"]?.bio == "retained biography")
        record.totalReadingTime = .nan
        tracker.updateRecord(record); precondition(!tracker.saveAllRecords(sync: true))
        record.totalReadingTime = 10
        tracker.updateRecord(record); precondition(tracker.saveAllRecords(sync: true))
        ReviewDefaults.standard.set(true, forKey: "enableReadingRecord")
        let a = NSObject(), b = NSObject()
        tracker.startTracking(documentID: "a", documentTitle: "A", pageIndex: 0, owner: ObjectIdentifier(a))
        tracker.stopTracking(owner: ObjectIdentifier(b)); precondition(tracker.currentRecord?.documentID == "a")
        tracker.startTracking(documentID: "b", documentTitle: "B", pageIndex: 0, owner: ObjectIdentifier(b))
        tracker.stopTracking(owner: ObjectIdentifier(a)); precondition(tracker.currentRecord?.documentID == "b")
        tracker.stopTracking(owner: ObjectIdentifier(b)); precondition(tracker.currentRecord == nil)
        print("PASS record/author async failure propagation, directory-switch protection, retry, encoding failure, active-window ownership")
    }
}
