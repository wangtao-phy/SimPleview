import SwiftUI
import AppKit

/// 录制只处理当前设置窗口。开始新录制会结束旧录制，离开窗口或页面时移除监听器。
struct ShortcutRecorderView: View {
    @Binding var shortcut: AppShortcut
    var validate: (AppShortcut) -> String? = { _ in nil }
    var onSave: () -> Void
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @State private var recording = false
    @State private var monitor: Any?
    @State private var window: NSWindow?
    @State private var error: String?
    @State private var id = UUID()
    private static let began = Notification.Name("ShortcutRecordingBegan")

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                if recording { stop() } else { start() }
            } label: {
                Text(recording ? L.s("Press any key...", language) : shortcut.displayString)
                    .monospaced().frame(minWidth: 100)
                    .foregroundStyle(recording ? Color.accentColor : .primary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 220, alignment: .trailing) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.began)) { notification in
            if notification.userInfo?["id"] as? UUID != id { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if notification.object as? NSWindow === window { stop() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        guard let keyWindow = NSApp.keyWindow else { return }
        NotificationCenter.default.post(name: Self.began, object: nil, userInfo: ["id": id])
        error = nil; window = keyWindow; recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window, window?.isKeyWindow == true else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53 { stop(); return nil }
            guard let key = event.charactersIgnoringModifiers?.lowercased().first else { return event }
            var flags: EventModifiers = []
            if modifiers.contains(.command) { flags.insert(.command) }
            if modifiers.contains(.control) { flags.insert(.control) }
            if modifiers.contains(.option) { flags.insert(.option) }
            if modifiers.contains(.shift) { flags.insert(.shift) }
            let candidate = AppShortcut(key: key, modifiers: flags)
            if let message = validate(candidate) { error = message; return nil }
            shortcut = candidate
            onSave()
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        recording = false; window = nil
    }
}
