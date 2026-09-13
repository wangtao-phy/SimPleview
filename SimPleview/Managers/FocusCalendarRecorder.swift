import Foundation
import Combine
@preconcurrency import EventKit

/// 先原子保存待写记录，再提交 EventKit。权限不足、写入失败和退出时均保留记录，
/// 重试用稳定的会话 URL 检查重复，不因“已保存但尚未清队列”的中断重复创建日程。
@MainActor
final class FocusCalendarRecorder: ObservableObject {
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private var pending: [FocusRecord] = []
    private let fileURL: URL
    private var loadError: Error?
    private lazy var calendar = EventManager(observesChanges: false)

    init(fileURL: URL = URL.applicationSupportDirectory
        .appendingPathComponent("SimPleview/FocusSessions.json")) {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { pending = try JSONDecoder().decode([FocusRecord].self, from: Data(contentsOf: fileURL)) }
            catch { loadError = error; lastError = error.localizedDescription }
        }
        pendingCount = pending.count
    }

    func enqueue(_ records: [FocusRecord]) {
        guard !records.isEmpty else { return }
        let existing = Set(pending.map(\.id))
        pending += records.filter { !existing.contains($0.id) }
        pendingCount = pending.count
        _ = persist()
    }

    @discardableResult
    func persist() -> Bool {
        do {
            // 无法读取旧队列时不能用空数组覆盖它。
            if let loadError { throw loadError }
            guard !pending.isEmpty || FileManager.default.fileExists(atPath: fileURL.path) else { return true }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    var hasCalendarAccess: Bool { authorizationStatus == .fullAccess }

    func refreshAuthorization() {
        // 日历权限属于整个应用；待办已获得的权限在这里直接生效。
        calendar.updateAuthStatuses()
        authorizationStatus = calendar.calendarAuthStatus
    }

    @discardableResult
    func authorizeCalendar() async -> Bool {
        guard !isRequestingAccess else { return false }
        refreshAuthorization()
        if hasCalendarAccess { return true }
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            calendar.openCalendarPrivacySettings()
            return false
        }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        do {
            // 首次授权或从“仅写入”升级；不受待写队列的磁盘错误影响。
            _ = try await calendar.eventStore.requestFullAccessToEvents()
        } catch { lastError = error.localizedDescription }
        refreshAuthorization()
        return hasCalendarAccess
    }

    func flush(requestAccess: Bool = false) async {
        guard !isSaving, !pending.isEmpty || requestAccess else { return }
        isSaving = true
        defer { isSaving = false }
        if requestAccess { _ = await authorizeCalendar() }
        refreshAuthorization()
        guard hasCalendarAccess, persist() else { return }
        lastError = nil
        while let record = pending.first {
            do {
                try Self.write(record, using: calendar)
                pending.removeFirst()
                if !persist() {
                    pending.insert(record, at: 0)
                    pendingCount = pending.count
                    return
                }
                pendingCount = pending.count
            } catch { lastError = error.localizedDescription; return }
            // 每条记录间让出主线程；通常一次仅一条，恢复积压时也不阻塞整个界面。
            await Task.yield()
        }
    }

    static func write(_ record: FocusRecord, using manager: EventManager) throws {
        guard record.end > record.start else { return }
        guard let calendar = manager.getOrCreateSimPleviewEventCalendar(), calendar.allowsContentModifications else {
            throw NSError(domain: "FocusCalendar", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L.s("Focus Calendar Unavailable",
                            UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .zh)])
        }
        let store = manager.eventStore
        let identifier = URL(string: "simpleview://reading-session/\(record.id.uuidString)")!
        let predicate = store.predicateForEvents(withStart: record.start, end: record.end, calendars: [calendar])
        guard !store.events(matching: predicate).contains(where: { $0.url == identifier }) else { return }
        let language = UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .zh
        let title = L.s(record.kind == .pomodoro ? "Pomodoro" : "Reading Session", language)
        let event = EKEvent(eventStore: store)
        event.title = record.documents.first.map { "\(title)：\($0)" } ?? title
        event.startDate = record.start; event.endDate = record.end
        event.calendar = calendar; event.url = identifier
        event.notes = record.documents.joined(separator: "\n")
        try store.save(event, span: .thisEvent, commit: true)
    }
}
