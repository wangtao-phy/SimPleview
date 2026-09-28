import SwiftUI
import PDFKit

/// 兼容阅读沿用会话的页码、目录和搜索跳转。页面按可见范围懒加载，缩放
/// 结束后才按新分辨率重绘；滚动和手势期间沿用已显示图像，不重复解析整本书。
struct SoftwarePDFView: View {
    @ObservedObject var session: NotebookSession
    let renderer: SoftwarePageRenderer
    @Environment(\.displayScale) private var displayScale
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 24) * zoom
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 12) {
                    ForEach(0..<(session.document?.pageCount ?? 0), id: \.self) { index in
                        let ratio = aspectRatio(at: index)
                        SoftwarePageView(renderer: renderer, index: index,
                            dimension: Int(min(4096, max(width, width / ratio) * displayScale)))
                            .frame(width: width, height: width / ratio)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
                .padding(12)
                .scaleEffect(magnification, anchor: .topLeading)
            }
            // 滚动和工具栏跳页共用会话页码，不另存一份需要双向同步的状态。
            .scrollPosition(id: Binding<Int?>(
                get: { session.pageIndex },
                set: { if let page = $0, page != session.pageIndex { session.pageIndex = page } }
            ), anchor: .top)
            .simultaneousGesture(MagnifyGesture()
                .updating($magnification) { value, state, _ in state = value.magnification }
                .onEnded { zoom = min(3, max(1, zoom * $0.magnification)) })
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await renderer.clearCache() }
        }
    }

    private func aspectRatio(at index: Int) -> CGFloat {
        guard let page = session.document?.page(at: index) else { return 1 }
        let size = page.bounds(for: .cropBox).size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return 1 }
        let ratio = page.rotation % 180 == 0 ? size.width / size.height : size.height / size.width
        // 损坏文件不能把 SwiftUI 布局撑成无限高度；绘制端仍独立校验实际尺寸。
        return min(20, max(0.05, ratio))
    }
}

private struct SoftwarePageView: View {
    let renderer: SoftwarePageRenderer
    let index: Int
    let dimension: Int
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Color.white
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if let failure {
                VStack {
                    Text(failure)
                    Button("重试") { attempt += 1 }
                }.foregroundStyle(.secondary)
            } else { ProgressView("第 \(index + 1) 页") }
        }
        .accessibilityLabel("第 \(index + 1) 页")
        .task(id: "\(dimension):\(attempt)") {
            failure = nil
            do {
                let data = try await renderer.image(page: index, maximumDimension: dimension)
                try Task.checkCancellation()
                guard let decoded = UIImage(data: data) else {
                    throw PadError.message("无法显示此页，请重试。")
                }
                image = decoded
            } catch is CancellationError {
                // 离屏取消不当作文件错误，也不清空正在显示的上一档清晰图像。
            } catch { failure = error.localizedDescription }
        }
        .onDisappear { image = nil }
    }
}
