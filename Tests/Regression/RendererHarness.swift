import AppKit
import WebKit

@MainActor final class RendererTest: NSObject, WKNavigationDelegate {
    let view = WKWebView()
    func start() {
        view.navigationDelegate = self
        let bundle = URL(fileURLWithPath: CommandLine.arguments[2])
        view.loadFileURL(bundle.appendingPathComponent("index.html"), allowingReadAccessTo: bundle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL renderer timeout"); exit(1) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let hostile = #"<img src='https://example.invalid/pixel' onerror='window.compromised=true'><script>window.compromised=true</script><iframe src='file:///etc/passwd'></iframe><a href='javascript:alert(1)'>bad</a>"# + "\n\n" + #"**bold** $x_i^2$ \(\frac{a_b}{c}\)"#
        view.callAsyncJavaScript("""
            renderContent(markdown);
            const content = document.getElementById('content');
            const ok = !window.compromised && !content.querySelector('script,img,iframe,[onerror]') &&
                !content.querySelector('a[href^="javascript"]') && content.querySelectorAll('.katex').length === 2 &&
                content.querySelector('strong').textContent === 'bold';
            const blocked = await fetch('https://example.invalid/pixel').then(() => false, () => true);
            return {ok, blocked, math:content.querySelectorAll('.katex').length, html:content.innerHTML};
            """, arguments: ["markdown": hostile], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    guard let info = value as? [String: Any], info["ok"] as? Bool == true,
                          info["blocked"] as? Bool == true else { print("FAIL renderer", value); exit(1) }
                    print("PASS offline WebKit Markdown/math rendering, HTML injection removal, CSP network block")
                    exit(0)
                case .failure(let error): print("FAIL renderer", error); exit(1)
                }
            }
    }
}
@main struct RendererHarness {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let test = RendererTest(); test.start()
        withExtendedLifetime(test) { app.run() }
    }
}
