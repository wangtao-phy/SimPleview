import UIKit
import PDFKit

/// 卷页复用 PDFView；笔迹由会话持有，不因动画预览或切换显示模式而丢失。
/// 相邻两页使用临时预览参与系统动画；动画结束后重新放入同一个可选字 PDFView。
@MainActor final class PDFReaderController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let pdfView: PDFView
    private let session: NotebookSession
    private var book: UIPageViewController?
    private var currentIndex = 0
    private var turning = false
    private var pendingIndex: Int?
    private var revision = -1
    private var previews: [Int: UIImage] = [:]
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()

    init(pdfView: PDFView, session: NotebookSession) {
        self.pdfView = pdfView; self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = UIView()
        view.backgroundColor = .secondarySystemBackground
        attachPDF(to: self)
    }
    deinit { previewTask?.cancel() }

    private func attachPDF(to controller: UIViewController) {
        pdfView.removeFromSuperview()
        pdfView.frame = controller.view.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(pdfView)
    }
    func update() {
        loadViewIfNeeded()
        let curl = session.adjustingInk ? book != nil : session.pageTurning == .curl && !session.writing
            && !UIAccessibility.isReduceMotionEnabled
        // 调整时保留原页与覆盖视图，只暂停卷页手势，不拆掉选中的笔迹画布。
        book?.gestureRecognizers.forEach { $0.isEnabled = !session.adjustingInk }
        if !curl {
            if book != nil {
                previewTask?.cancel(); previewTask = nil; previews.removeAll()
                previewGeneration = UUID(); turning = false; pendingIndex = nil
                book?.dataSource = nil; book?.delegate = nil
                attachPDF(to: self)
                book?.willMove(toParent: nil); book?.view.removeFromSuperview(); book?.removeFromParent()
                book = nil
                pdfView.displayMode = .singlePageContinuous
                if let page = session.document?.page(at: session.pageIndex) { pdfView.go(to: page) }
            }
            return
        }
        if book == nil {
            pdfView.displayMode = .singlePage
            let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                                  options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
            book = controller
            controller.gestureRecognizers.forEach { $0.isEnabled = !session.adjustingInk }
            controller.isDoubleSided = false
            controller.dataSource = self; controller.delegate = self
            addChild(controller); controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controller.view); controller.didMove(toParent: self)
            show(session.pageIndex)
        } else if turning {
            if session.pageIndex != currentIndex { pendingIndex = session.pageIndex }
            return
        } else if currentIndex != session.pageIndex {
            show(session.pageIndex)
        }
        if revision != session.revision { revision = session.revision; previews.removeAll(); prepareNeighbors() }
    }
    private func show(_ index: Int) {
        guard let book, let document = session.document, (0..<document.pageCount).contains(index) else { return }
        let direction: UIPageViewController.NavigationDirection = index >= currentIndex ? .forward : .reverse
        currentIndex = index
        if revision != session.revision { previews.removeAll(); revision = session.revision }
        let face = Face(index: index, image: nil)
        book.setViewControllers([face], direction: direction, animated: false)
        attachPDF(to: face)
        prepareNeighbors()
    }
    private func prepareNeighbors() {
        previewTask?.cancel()
        let generation = UUID(); previewGeneration = generation
        guard book != nil, let document = session.document else { return }
        let indices = [currentIndex - 1, currentIndex + 1].filter { (0..<document.pageCount).contains($0) }
        previews = previews.filter { indices.contains($0.key) }
        let missing = indices.filter { previews[$0] == nil }
        guard !missing.isEmpty, let snapshot = try? session.snapshot() else { return }
        let storage = session.storage
        // 一次最多两张，最长边 1536；不缓存整本文档的动画图像。
        previewTask = Task(priority: .utility) { [weak self] in
            guard let images = try? await storage.images(snapshot, pages: missing, maximumDimension: 1536),
                  !Task.isCancelled, let self, self.previewGeneration == generation else { return }
            for image in images { self.previews[image.pageNumber-1] = UIImage(data: image.jpeg) }
            guard !self.turning, let book = self.book, let face = book.viewControllers?.first else { return }
            // 初次询问相邻页时预览可能尚未完成。重新提交当前面，令系统刷新
            // 边缘翻页的可用方向；不新建 PDFView，也不跳动当前阅读位置。
            book.setViewControllers([face], direction: .forward, animated: false)
        }
    }
    private func neighbor(_ index: Int) -> UIViewController? {
        // 未准备好的页面不开始卷页，避免翻到空白占位；本页 PDF 始终可正常阅读。
        guard let image = previews[index] else { return nil }
        return Face(index: index, image: image)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let face = viewController as? Face else { return nil }
        return neighbor(face.index - 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let face = viewController as? Face else { return nil }
        return neighbor(face.index + 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        turning = true
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        turning = false
        if let requested = pendingIndex {
            pendingIndex = nil; show(requested)
        } else if completed, let face = pageViewController.viewControllers?.first as? Face {
            currentIndex = face.index
            session.go(to: face.index)
            attachPDF(to: face)
            prepareNeighbors()
        }
        update()
    }
    func stop() {
        previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil
        book?.dataSource = nil; book?.delegate = nil
        previews.removeAll()
    }

    private final class Face: UIViewController {
        let index: Int
        private let image: UIImage?
        init(index: Int, image: UIImage?) { self.index = index; self.image = image; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { nil }
        override func loadView() {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .secondarySystemBackground
            imageView.isUserInteractionEnabled = true
            view = imageView
        }
    }
}

enum PageTurning: String, CaseIterable, Identifiable {
    case continuous, curl
    var id: String { rawValue }
    var title: String { self == .continuous ? "连续滚动" : "仿真翻书" }
}
