import Foundation

/// Date 仅用于日历起止时间；ContinuousClock 在调时和休眠后仍能正确计算经过时间。
nonisolated struct FocusMoment {
    let date: Date
    let instant: ContinuousClock.Instant
    static var now: Self { .init(date: Date(), instant: .now) }
    func elapsed(since earlier: Self) -> TimeInterval {
        let parts = earlier.instant.duration(to: instant).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

nonisolated struct FocusRecord: Codable, Equatable {
    enum Kind: String, Codable { case pomodoro, reading }
    let id: UUID
    let kind: Kind
    let start: Date
    let end: Date
    let documents: [String]
}

/// 纯状态机，不读取窗口、不写日历，边界情况可用模拟时间验证，无需等待一小时。
nonisolated struct FocusSessionClock {
    enum Outcome { case idle, running, awaitingReturn, completed, failed, cancelled }
    private struct Pomodoro {
        let start: FocusMoment
        let duration: TimeInterval
        let documents: [String]
    }
    private var pomodoro: Pomodoro?
    private var awaySince: FocusMoment?
    private var readingStart: FocusMoment?
    private var readingDocuments: [String] = []
    private var active = false
    private var document: String?
    private(set) var outcome = Outcome.idle
    var isRunning: Bool { pomodoro != nil }

    func remaining(at now: FocusMoment) -> Int {
        guard let pomodoro else { return 0 }
        return Int(ceil(max(0, pomodoro.duration - now.elapsed(since: pomodoro.start))))
    }

    mutating func start(minutes: Int, document title: String?, at now: FocusMoment) -> [FocusRecord] {
        guard !isRunning, (1...180).contains(minutes) else { return [] }
        let records = finishReading(at: now)
        pomodoro = .init(start: now, duration: Double(minutes * 60), documents: title.map { [$0] } ?? [])
        awaySince = active ? nil : now
        outcome = .running
        return records
    }

    /// 先结算旧状态，再处理前后台切换；恰好离开 300 秒时，失败优先于完成。
    mutating func update(active: Bool, document: String?, at now: FocusMoment) -> [FocusRecord] {
        var records = advance(at: now)
        if self.active && !active, isRunning { awaySince = now }
        if !self.active && active { awaySince = nil }
        self.active = active
        self.document = document
        records += advance(at: now)
        if active, let document, !isRunning {
            if readingStart == nil { readingStart = now }
            if !readingDocuments.contains(document) { readingDocuments.append(document) }
        } else {
            records += finishReading(at: now)
        }
        return records
    }

    mutating func advance(at now: FocusMoment) -> [FocusRecord] {
        guard let run = pomodoro else { return [] }
        if let awaySince {
            if now.elapsed(since: awaySince) >= 300 {
                pomodoro = nil; self.awaySince = nil; outcome = .failed
            } else if now.elapsed(since: run.start) >= run.duration {
                outcome = .awaitingReturn
            }
            return []
        }
        guard now.elapsed(since: run.start) >= run.duration else { return [] }
        pomodoro = nil; outcome = .completed
        // 不把计时器延迟回调的时间算进已完成番茄钟。
        let result = FocusRecord(id: UUID(), kind: .pomodoro, start: run.start.date,
                                 end: run.start.date.addingTimeInterval(run.duration), documents: run.documents)
        if active, let document {
            readingStart = now; readingDocuments = [document]
        }
        return [result]
    }

    mutating func cancel(at now: FocusMoment) {
        guard isRunning else { return }
        pomodoro = nil; awaySince = nil; outcome = .cancelled
        if active, let document { readingStart = now; readingDocuments = [document] }
    }

    mutating func stop(at now: FocusMoment) -> [FocusRecord] {
        var records = advance(at: now)
        records += finishReading(at: now)
        if isRunning { outcome = .cancelled }
        pomodoro = nil; awaySince = nil; active = false; document = nil
        return records
    }

    private mutating func finishReading(at now: FocusMoment) -> [FocusRecord] {
        defer { readingStart = nil; readingDocuments = [] }
        guard let start = readingStart, now.elapsed(since: start) >= 3600 else { return [] }
        return [.init(id: UUID(), kind: .reading, start: start.date,
                      end: start.date.addingTimeInterval(now.elapsed(since: start)), documents: readingDocuments)]
    }
}
