import SwiftUI
import Combine

import AppKit

/// 主应用生命周期与设置场景；阅读窗口由 AppDelegate 管理，预览子进程不经过这里。
struct SimpleViewApp: App {
    
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    init() {
        #if os(macOS)
        // 文档窗口由自己的恢复记录管理，避免与系统窗口恢复重复。
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        // 普通文件默认作为标签页打开，独立分组由窗口管理功能负责。
        NSWindow.allowsAutomaticWindowTabbing = true
        
        _ = MemoryManager.shared
        #endif
    }
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
        .defaultSize(width: 720, height: 780)
        .windowResizability(.contentMinSize)
    }
}


@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @AppStorage("autoCheckUpdates") var autoCheckUpdates: Bool = true
    
    private var midnightTimer: Timer?
    private var isCheckingUpdates = false
    private var manualUpdateRequested = false
    
    private init() {
    }
    
    func startMonitoring() {
        if autoCheckUpdates {
            checkForUpdates(manual: false)
        }
        scheduleMidnightCheck()
    }
    
    private func scheduleMidnightCheck() {
        midnightTimer?.invalidate()
        
        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.day? += 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        
        guard let midnight = Calendar.current.date(from: components) else { return }
        let timeInterval = midnight.timeIntervalSince(now)
        
        midnightTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.autoCheckUpdates {
                    self.checkForUpdates(manual: false)
                }
                self.scheduleMidnightCheck()
            }
        }
    }
    
    func checkForUpdates(manual: Bool) {
        guard NSApp.modalWindow == nil, NSApp.keyWindow?.sheetParent == nil,
              NSApp.keyWindow?.attachedSheet == nil,
              !(NSApp.keyWindow is NSSavePanel) else { return }
        manualUpdateRequested = manualUpdateRequested || manual
        // 手动检查与定时检查合并为同一次请求，不能叠加更新弹窗。
        guard !isCheckingUpdates else { return }
        guard let url = URL(string: "https://api.github.com/repos/wangtao-phy/SimPleview/releases/latest") else { return }
        isCheckingUpdates = true
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let manual = self.manualUpdateRequested
                defer { self.isCheckingUpdates = false; self.manualUpdateRequested = false }
                // 网络返回时，用户可能已在另一个保存或打印对话框里。
                guard NSApp.isActive, NSApp.modalWindow == nil, NSApp.keyWindow?.sheetParent == nil,
                      NSApp.keyWindow?.attachedSheet == nil,
                      !(NSApp.keyWindow is NSSavePanel) else { return }
                guard let data = data, error == nil else {
                    if manual {
                        self.showNetworkError()
                    }
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let tagName = json["tag_name"] as? String,
                       let htmlUrlStr = json["html_url"] as? String,
                       let htmlUrl = URL(string: htmlUrlStr) {
                        
                        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                        
                        let cleanTag = tagName.replacingOccurrences(of: "v", with: "")
                        let cleanCurrent = currentVersion.replacingOccurrences(of: "v", with: "")
                        
                        if cleanTag.compare(cleanCurrent, options: .numeric) == .orderedDescending {
                            // 自动提示每个版本只出现一次，手动检查仍可主动查看。
                            guard manual || UserDefaults.standard.string(forKey: "lastNotifiedUpdateVersion") != tagName else { return }
                            UserDefaults.standard.set(tagName, forKey: "lastNotifiedUpdateVersion")
                            self.showUpdateAvailableAlert(newVersion: tagName, url: htmlUrl)
                        } else {
                            if manual {
                                self.showUpToDateAlert()
                            }
                        }
                    } else {
                        if manual {
                            self.showNetworkError()
                        }
                    }
                } catch {
                    if manual {
                        self.showNetworkError()
                    }
                }
            }
        }
        task.resume()
    }
    
    private func getLS(_ key: String) -> String {
        let langStr = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh"
        let lang: AppLanguage = langStr == "en" ? .en : .zh
        return SimPleview.L.s(key, lang)
    }
    
    #if os(macOS)
    private func showUpdateAvailableAlert(newVersion: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = getLS("Update Available")
        alert.informativeText = getLS("A new version is available!") + " (\(newVersion))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: getLS("Download"))
        alert.addButton(withTitle: getLS("Cancel"))
        
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = getLS("Up to date")
        alert.informativeText = getLS("You are using the latest version of SimPleview.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: getLS("OK"))
        alert.runModal()
    }
    
    private func showNetworkError() {
        let alert = NSAlert()
        alert.messageText = getLS("Network error while checking for updates.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: getLS("OK"))
        alert.runModal()
    }
    #endif
}
