import Foundation

/// 外部文档产生的路径始终作为 argv 的一个参数传递。绝不进入 sh -c，
/// 因此引号、反引号、$() 都只是文件名字符，不能改变命令含义。
nonisolated enum SyncTeXLauncher {
    static func sourceArguments(path: String, line: Int) -> [String] { ["-g", "\(path):\(line)"] }

    static func openSource(from output: String, relativeTo pdfURL: URL) throws {
        var input: String?
        var line: Int?
        for text in output.components(separatedBy: .newlines) {
            if text.hasPrefix("Input:") { input = String(text.dropFirst(6)) }
            if text.hasPrefix("Line:") { line = Int(text.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
        }
        guard let input, !input.isEmpty, let line, line > 0, line <= 100_000_000 else { return }
        let source = URL(fileURLWithPath: input, relativeTo: pdfURL.deletingLastPathComponent()).standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let candidates = ["/usr/local/bin/code", "/opt/homebrew/bin/code",
                          "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"]
        let process = Process()
        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = sourceArguments(path: source.path, line: line)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Visual Studio Code", source.path]
        }
        try process.run()
    }

    static func edit(pdfURL: URL, page: Int, x: CGFloat, y: CGFloat) {
        guard x.isFinite, y.isFinite else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/Library/TeX/texbin:/usr/local/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.arguments = ["synctex", "edit", "-o", "\(page):\(x):\(y):\(pdfURL.path)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // 先持续排空管道，再 waitUntilExit；反过来会在子进程写满管道时死锁。
            // 时间和输出量双重上限，避免损坏的工具/输入永久占用后台线程。
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
            var output = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                guard output.count + chunk.count <= 1_048_576 else { process.terminate(); return }
                output.append(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else { return }
            try openSource(from: text, relativeTo: pdfURL)
        } catch {
            // 工具未安装或源码不存在只影响跳转，不应影响 PDF 的编辑/保存。
            NSLog("SyncTeX: %@", error.localizedDescription)
        }
    }
}
