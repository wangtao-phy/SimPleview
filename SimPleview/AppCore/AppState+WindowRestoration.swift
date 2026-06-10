import SwiftUI

/// [教程注释：高级窗口还原与外部应用调用]
extension AppState {
    
    #if os(macOS)
    // [逻辑流程：启动时恢复上一次未关闭的窗口]
    // 因为苹果自带的状态恢复（Restoration）和我们的 App Sandbox（沙盒）机制经常冲突。
    // 所以我们决定自己接管！
    @MainActor
    static func startRestoreChain(openWindow: @escaping (URL) -> Void) {
        guard let dict = UserDefaults.standard.dictionary(forKey: "OpenedPDFBookmarks") as? [String: Data], !dict.isEmpty else { return }
        
        let paths = dict.keys.sorted() // 保证打开顺序不变
        var urls = [URL]()
        
        for path in paths {
            guard let data = dict[path] else { continue }
            do {
                var isStale = false
                // 最最最核心的一步：拿着以前留存下的 Bookmark Data 去向系统换一张最新的通行证 (URL)！
                // 选项 `withSecurityScope` 意味着这张通行证可以突破沙盒限制。
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
                if !isStale {
                    urls.append(url)
                }
            } catch {
                // 如果文件被用户删除了，解析就会失败，这个时候顺手把它从字典里清理掉
                var currentDict = UserDefaults.standard.dictionary(forKey: "OpenedPDFBookmarks") as? [String: Data] ?? [:]
                currentDict.removeValue(forKey: path)
                UserDefaults.standard.set(currentDict, forKey: "OpenedPDFBookmarks")
            }
        }
        
        guard !urls.isEmpty else { return }
        
        // 把所有的 URL 都推给排队系统，由系统统一负责打开真正的窗口！
        for url in urls {
            openWindow(url)
        }
    }
    

    
    // 如果是单个文档通过右键或者某种方式传过来的，进行孤立解析
    func resolveSecurityURL(url: URL) -> URL {
        guard let dict = UserDefaults.standard.dictionary(forKey: "OpenedPDFBookmarks") as? [String: Data],
              let data = dict[url.path] else { return url }
        do {
            var isStale = false
            return try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
        } catch { return url }
    }
    #endif

    // [逻辑流程：在访达 (Finder) 中显示这个文件]
    func revealInFinder() { guard let url = fileURL else { return }; PlatformUtils.revealInFinder(url: url) }
    
    // [高级功能：调起外部程序打开当前 PDF]
    func openInBrowser() {
        guard let url = fileURL else { return }
        
        #if os(macOS)
        let browserPrefStr = UserDefaults.standard.string(forKey: "externalBrowser") ?? "Default"
        let browserPref = ExternalBrowser(rawValue: browserPrefStr) ?? .defaultBrowser
        let customPath = UserDefaults.standard.string(forKey: "customBrowserPath") ?? ""
        
        var targetAppURL: URL? = nil
        
        // [用户偏好设置判断]
        if browserPref == .other && !customPath.isEmpty {
            let customURL = URL(fileURLWithPath: customPath)
            if FileManager.default.fileExists(atPath: customURL.path) {
                targetAppURL = customURL
            }
        } else if browserPref != .defaultBrowser {
            // 通过 BundleID 去系统注册表里查询这个 App 的绝对路径
            for bundleID in browserPref.bundleIdentifiers {
                if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    targetAppURL = u
                    break
                }
            }
            // 如果查不到，用写死在 Application 下的名字碰碰运气
            if targetAppURL == nil, let appName = browserPref.appName {
                let fallbackURL = URL(fileURLWithPath: "/Applications/\(appName).app")
                if FileManager.default.fileExists(atPath: fallbackURL.path) {
                    targetAppURL = fallbackURL
                }
            }
        }
        
        // 如果依然失败，默认用系统里能够处理 "http" 的默认浏览器（通常是 Safari 或者 Chrome）
        if targetAppURL == nil {
            targetAppURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "http://google.com")!)
        }
        
        // 使用 NSWorkspace 的 open 接口强制用指定的应用程序打开我们现在的 PDF！
        if let browserURL = targetAppURL {
            NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        #else
        // iOS 非常简单粗暴，交由系统决定去哪个软件里
        UIApplication.shared.open(url)
        #endif
    }
    
    // 从最近打开的历史记录清理掉本文件
    func removeFromOpenedRecent() {
        documentManager.removeFromOpenedRecent(url: fileURL)
    }
}
