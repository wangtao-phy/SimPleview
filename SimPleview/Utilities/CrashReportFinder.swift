import Foundation

/// 只读调用者指定目录中的系统报告。由后台任务调用；不安装异常处理器，也不上传日志。
nonisolated enum CrashReportFinder {
    struct Identity: Codable, Sendable {
        let pid: Int32
        let launchedAt: Date
        let executable: String
        let bundleIdentifier: String
    }

    struct Report: Sendable {
        let url: URL
        let text: String
        let isTruncated: Bool
    }

    private static let readLimit = 8 * 1_024 * 1_024
    private static let displayLimit = 2 * 1_024 * 1_024
    private static let launchTolerance: TimeInterval = 2

    /// before 是下一次主进程启动时间，而不是报告文件写完的时间。系统可能稍后才
    /// 写出报告，因此只用文件修改时间排除旧文件，最终以报告内的进程时间确认。
    static func latestReport(for identity: Identity, in directories: [URL], before: Date) -> Report? {
        guard identity.pid > 0, !identity.executable.isEmpty, before >= identity.launchedAt else { return nil }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey,
                                        .isRegularFileKey, .isSymbolicLinkKey]
        var candidates: [(url: URL, modified: Date)] = []
        let locations = directories.flatMap { directory in
            directory.lastPathComponent == "Retired" ? [directory] :
                [directory, directory.appendingPathComponent("Retired", isDirectory: true)]
        }
        for directory in Set(locations) {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { continue }
            for url in urls {
                let kind = url.pathExtension.lowercased()
                let name = url.deletingPathExtension().lastPathComponent
                guard kind == "ips" || kind == "crash",
                      name == identity.executable || name.hasPrefix(identity.executable + "-") ||
                        name.hasPrefix(identity.executable + "_"),
                      let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= readLimit,
                      let modified = values.contentModificationDate,
                      modified >= identity.launchedAt.addingTimeInterval(-launchTolerance) else { continue }
                candidates.append((url, modified))
            }
        }
        // 不遍历其它应用的报告，也不随目录历史增长解析量。大解析对象每份及时释放。
        var seen = Set<URL>()
        var latest: (report: Report, captured: Date)?
        for candidate in candidates.sorted(by: { $0.modified > $1.modified }).prefix(32) {
            guard seen.insert(candidate.url).inserted else { continue }
            let match: (report: Report, captured: Date)? = autoreleasepool {
                guard let file = try? FileHandle(forReadingFrom: candidate.url) else { return nil }
                defer { try? file.close() }
                guard let data = try? file.read(upToCount: readLimit + 1),
                      !data.isEmpty, data.count <= readLimit else { return nil }
                let captured = candidate.url.pathExtension.lowercased() == "ips"
                    ? captureTime(inJSON: data, identity: identity, before: before)
                    : captureTime(inText: data, identity: identity, before: before)
                guard let captured else { return nil }
                let report = Report(url: candidate.url,
                    text: String(decoding: data.prefix(displayLimit), as: UTF8.self),
                    isTruncated: data.count > displayLimit)
                return (report, captured)
            }
            guard let match else { continue }
            if let current = latest, match.captured <= current.captured { continue }
            latest = match
        }
        return latest?.report
    }

    private static func captureTime(inJSON data: Data, identity: Identity, before: Date) -> Date? {
        // Apple .ips 由两个独立 JSON 对象组成；不能把整份报告当作一个 JSON 解析。
        guard let boundary = firstObjectEnd(in: data),
              let metadata = try? JSONSerialization.jsonObject(with: data[..<boundary]) as? [String: Any],
              metadata["bug_type"] as? String == "309",
              let report = try? JSONSerialization.jsonObject(with: data[boundary...]) as? [String: Any],
              (report["isNonFatal"] as? NSNumber)?.boolValue != true,
              (report["isSimulated"] as? NSNumber)?.boolValue != true,
              let pid = report["pid"] as? NSNumber, pid.stringValue == String(identity.pid),
              let launched = report["procLaunch"] as? String,
              let captured = report["captureTime"] as? String else { return nil }
        let process = report["procName"] as? String
        let bundle = (report["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String
        let metadataBundle = metadata["bundleID"] as? String
        guard matches(identity, process: process, bundles: [bundle, metadataBundle]) else { return nil }
        return matchingTime(launched: launched, captured: captured, identity: identity, before: before)
    }

    private static func captureTime(inText data: Data, identity: Identity, before: Date) -> Date? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.prefix(64 * 1_024).split(separator: "\n").prefix(100) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if fields[key] == nil {
                fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let processLine = fields["Process"], processLine.hasSuffix("]"),
              let bracket = processLine.lastIndex(of: "["),
              Int32(processLine[processLine.index(after: bracket)..<processLine.index(before: processLine.endIndex)]) == identity.pid,
              let launched = fields["Launch Time"], let captured = fields["Date/Time"],
              let exception = fields["Exception Type"], !exception.isEmpty,
              !text.prefix(64 * 1_024).contains("NON-FATAL CONDITION") else { return nil }
        let process = String(processLine[..<bracket]).trimmingCharacters(in: .whitespaces)
        guard matches(identity, process: process, bundles: [fields["Identifier"]]) else { return nil }
        // 老报告没有 Launch Time 时不能可靠排除 PID 复用，宁可不自动关联。
        return matchingTime(launched: launched, captured: captured, identity: identity, before: before)
    }

    private static func matches(_ identity: Identity, process: String?, bundles: [String?]) -> Bool {
        let bundleIDs = bundles.compactMap { $0 }.filter { !$0.isEmpty }
        guard process != nil || !bundleIDs.isEmpty else { return false }
        return (process == nil || process == identity.executable) &&
            bundleIDs.allSatisfy { $0 == identity.bundleIdentifier }
    }

    private static func matchingTime(launched: String, captured: String,
                                     identity: Identity, before: Date) -> Date? {
        // Formatter 只属于当前后台调用，不使用跨线程共享的可变日期解析器。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS Z"
        formatter.isLenient = false
        func date(_ value: String) -> Date? {
            if let date = formatter.date(from: value) { return date }
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            let date = formatter.date(from: value)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS Z"
            return date
        }
        guard let launch = date(launched), let capture = date(captured),
              abs(launch.timeIntervalSince(identity.launchedAt)) <= launchTolerance,
              capture >= launch, capture <= before else { return nil }
        return capture
    }

    private static func firstObjectEnd(in data: Data) -> Data.Index? {
        var depth = 0, quoted = false, escaped = false, started = false
        for index in data.indices {
            let byte = data[index]
            if !started {
                if byte == 32 || byte == 9 || byte == 10 || byte == 13 { continue }
                guard byte == 123 else { return nil }
                started = true
            }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0 { return data.index(after: index) }
            }
        }
        return nil
    }
}
