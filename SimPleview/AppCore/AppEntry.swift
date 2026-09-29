import SwiftUI

/// 同一可执行文件包含轻量的 PDF 预览工作模式；常规启动仍进入原有 SwiftUI 应用。
@main enum AppEntry {
    static func main() {
        LinkPreviewRenderer.runWorkerIfRequested()
        SimpleViewApp.main()
    }
}
