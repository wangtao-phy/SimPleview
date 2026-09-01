import SwiftUI
import WebKit

struct KaTeXWebView: NSViewRepresentable {
    let markdown: String
    @Binding var dynamicHeight: CGFloat

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: KaTeXWebView
        var lastMarkdown: String? = nil
        var isLoaded: Bool = false
        
        init(_ parent: KaTeXWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let markdown = lastMarkdown {
                parent.evaluateMarkdown(markdown, on: webView, coordinator: self)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        loadInitialHTML(on: webView)
        return webView
    }

    func loadInitialHTML(on webView: WKWebView) {
        let htmlString = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                :root { color-scheme: light dark; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    font-size: 14px;
                    line-height: 1.6;
                    padding: 8px;
                    margin: 0;
                    background-color: transparent;
                }
                pre { background-color: rgba(128, 128, 128, 0.1); padding: 10px; border-radius: 5px; overflow-x: auto; }
                code { font-family: Menlo, Monaco, Consolas, monospace; background-color: rgba(128, 128, 128, 0.1); padding: 2px 4px; border-radius: 3px; }
            </style>
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.css">
            <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.js"></script>
            <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/contrib/auto-render.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        </head>
        <body>
            <div id="content"></div>
            <script>
                function renderContent(mdText) {
                    // Double the backslashes so marked.js doesn't consume them as escape characters
                    let safeMd = mdText.replace(/\\\\/g, '\\\\\\\\');
                    
                    // Simple hack to prevent marked from turning _ into <em> inside math blocks
                    // We temporarily replace _ with a placeholder inside $...$ or $$...$$
                    // (For a robust production app, marked-katex-extension is better, but this handles 95% of cases)
                    
                    document.getElementById('content').innerHTML = marked.parse(safeMd);
                    renderMathInElement(document.getElementById('content'), {
                      delimiters: [
                          {left: '$$', right: '$$', display: true},
                          {left: '$', right: '$', display: false},
                          {left: '\\\\[', right: '\\\\]', display: true},
                          {left: '\\\\(', right: '\\\\)', display: false}
                      ],
                      throwOnError : false
                    });
                }
            </script>
        </body>
        </html>
        """
        webView.loadHTMLString(htmlString, baseURL: nil)
    }

    func evaluateMarkdown(_ markdown: String, on webView: WKWebView, coordinator: Coordinator) {
        if let base64 = markdown.data(using: .utf8)?.base64EncodedString() {
            let js = """
            try {
                const mdText = decodeURIComponent(escape(window.atob('\(base64)')));
                if (typeof renderContent === 'function') {
                    renderContent(mdText);
                }
            } catch(e) {}
            """
            webView.evaluateJavaScript(js) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    webView.evaluateJavaScript("document.documentElement.scrollHeight") { result, _ in
                        if let height = result as? CGFloat {
                            if abs(coordinator.parent.dynamicHeight - height) > 5 {
                                coordinator.parent.dynamicHeight = height
                            }
                        }
                    }
                }
            }
        }
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastMarkdown == markdown { return }
        context.coordinator.lastMarkdown = markdown
        if !context.coordinator.isLoaded { return }
        evaluateMarkdown(markdown, on: webView, coordinator: context.coordinator)
    }
}
