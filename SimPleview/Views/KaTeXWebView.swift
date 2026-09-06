import SwiftUI
import WebKit

struct KaTeXWebView: NSViewRepresentable {
    let markdown: String
    @Binding var dynamicHeight: CGFloat

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: KaTeXWebView
        var latest: String?
        var rendered: String?
        var loaded = false
        var stopped = false
        var inFlight = false
        var pending: DispatchWorkItem?
        init(_ parent: KaTeXWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            schedule(on: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // 只允许首次打开本地资源。用户点击的 HTTP 链接由系统浏览器打开，
            // 模型生成的跳转以及 file/javascript 链接不能离开渲染资源目录。
            if action.navigationType == .linkActivated {
                if let url = action.request.url,
                   ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                return .cancel
            } else {
                return !loaded && action.request.url?.isFileURL == true ? .allow : .cancel
            }
        }

        func schedule(on view: WKWebView) {
            guard loaded, !stopped, !inFlight, latest != rendered, pending == nil else { return }
            // 流式回复只保留最新文本；最多一个 JS 调用执行、一个延迟任务待处理，
            // 避免每个 token 都创建闭包并长期持有 WKWebView。
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view, !self.stopped, let text = self.latest else { return }
                self.pending = nil
                self.inFlight = true
                self.rendered = text
                view.callAsyncJavaScript("return renderContent(markdown);",
                    arguments: ["markdown": text], in: nil, in: .page) { [weak self, weak view] result in
                    guard let self, !self.stopped else { return }
                    self.inFlight = false
                    if case .success(let value) = result, let number = value as? NSNumber {
                        let height = CGFloat(number.doubleValue)
                        if height.isFinite, height > 0, abs(self.parent.dynamicHeight - height) > 2 {
                            self.parent.dynamicHeight = min(30000, height)
                        }
                    }
                    if let view { self.schedule(on: view) }
                }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        if let resources = Bundle.main.url(forResource: "ChatRenderer", withExtension: "bundle") {
            view.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
        } else {
            view.loadHTMLString("<p>聊天渲染资源缺失，请重新安装应用。</p>", baseURL: nil)
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.latest = markdown
        context.coordinator.schedule(on: view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stopped = true
        coordinator.pending?.cancel()
        coordinator.pending = nil
        view.stopLoading()
        view.navigationDelegate = nil
    }
}
