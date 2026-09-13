import SwiftUI
import EventKit

struct FocusTimerView: View {
    @ObservedObject var manager: FocusSessionManager
    @ObservedObject var recorder: FocusCalendarRecorder
    @AppStorage("pomodoroMinutes") private var minutes = 25
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @State private var showAuthorizationConfirmation = false
    @State private var durationText = ""

    private func text(_ key: String) -> String { L.s(key, language) }

    // 输入草稿与已保存时长分开：允许清空后重输，但无效输入不能沿用旧值开始计时。
    private var enteredMinutes: Int? {
        guard let value = Int(durationText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...180).contains(value) else { return nil }
        return value
    }

    private var authorizationLabel: String {
        if recorder.hasCalendarAccess { return text("Calendar Authorized") }
        if recorder.authorizationStatus == .denied || recorder.authorizationStatus == .restricted {
            return text("Authorize Calendar in Settings")
        }
        return text("Authorize Calendar")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(manager.isRunning || manager.outcome == .completed ? manager.countdown : String(format: "%02d:00", minutes))
                .font(.system(size: 38, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(text("Remaining Time"))
            Text(manager.outcomeText).font(.callout).frame(maxWidth: .infinity)
            if let title = manager.documentTitle {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Text(text("Focus Duration"))
                Spacer()
                TextField("25", text: $durationText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .accessibilityLabel(text("Focus Duration"))
                Text(text("Minutes"))
            }
            .disabled(manager.isRunning || manager.isStarting || recorder.isRequestingAccess)
            Text(text("Focus Duration Range"))
                .font(.caption).foregroundStyle(enteredMinutes == nil ? Color.red : Color.secondary)
            Text(text("Focus Rules")).font(.caption).foregroundStyle(.secondary)
            HStack {
                if manager.isRunning {
                    Button(text("Cancel Pomodoro"), role: .destructive) { manager.cancel() }
                } else {
                    Button(text("Start Pomodoro")) {
                        guard let duration = enteredMinutes else { return }
                        Task { await manager.start(minutes: duration) }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(enteredMinutes == nil || manager.isStarting || recorder.isRequestingAccess)
                }
                Spacer()
            }
            Divider()
            if recorder.pendingCount > 0 {
                Text("\(text("Pending Calendar Records"))：\(recorder.pendingCount)").font(.caption)
                if !recorder.hasCalendarAccess {
                    Text(text("Focus Calendar Permission")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = recorder.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(authorizationLabel) {
                    Task { showAuthorizationConfirmation = await recorder.authorizeCalendar() }
                }
                if recorder.pendingCount > 0, recorder.hasCalendarAccess {
                    Button(text("Sync Calendar Records")) { Task { await recorder.flush() } }
                }
            }
            .disabled(recorder.isSaving || recorder.isRequestingAccess || manager.isStarting)
            .font(.caption)
            Text(text("Automatic Reading Rule")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 330)
        .onAppear {
            minutes = min(180, max(1, minutes))
            durationText = String(minutes)
            recorder.refreshAuthorization()
        }
        .onChange(of: durationText) { _, _ in
            // 仅保存合法整数；关闭弹出框后，再次打开仍使用最近一次有效设置。
            if let value = enteredMinutes { minutes = value }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recorder.refreshAuthorization()
        }
        .alert(text("Calendar Authorized"), isPresented: $showAuthorizationConfirmation) {
            Button(text("OK"), role: .cancel) { }
        } message: {
            Text(text("Calendar Authorization Shared"))
        }
    }
}

/// 使用真实按钮作为 NSPopover 的锚点，跟随工具栏布局，无需猜测屏幕坐标。
struct FocusTimerButton: NSViewRepresentable {
    var documentTitle: String?
    var label: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "timer", accessibilityDescription: label)!,
                              target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.isBordered = false
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.documentTitle = documentTitle
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        button.target = nil; button.action = nil
    }
    final class Coordinator: NSObject {
        var documentTitle: String?
        @objc func clicked(_ sender: NSButton) {
            FocusSessionManager.shared.togglePopover(relativeTo: sender, documentTitle: documentTitle)
        }
    }
}
