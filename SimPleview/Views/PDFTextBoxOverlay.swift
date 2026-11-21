import AppKit
import PDFKit
import os

/// 独立于 PDFKit 瓦片的透明视图。提交文字或拖动边框时只重绘文本框。
final class PDFTextBoxOverlay: NSView {
    private struct Item {
        let drawing: PDFTextBoxDrawing
        let transform: CGAffineTransform
        let frame: CGRect
        let pageClip: CGRect
        let selected: Bool
    }

    private weak var reader: CustomPDFView?
    private var items: [Item] = []
    private var inverted = false
    private let removeButton = NSButton()

    init(reader: CustomPDFView) {
        self.reader = reader
        super.init(frame: reader.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        let language = UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .zh
        let label = L.s("Delete Text Box", language)
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: label)
        removeButton.isBordered = false
        removeButton.contentTintColor = .controlAccentColor
        removeButton.toolTip = label
        removeButton.setAccessibilityLabel(label)
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.isHidden = true
        addSubview(removeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 正文仍由 PDFKit 接收事件；只有选中框的删除按钮需要响应。
        guard !isHidden, !removeButton.isHidden else { return nil }
        return removeButton.hitTest(convert(point, from: superview))
    }

    func refresh() {
        guard let reader, !reader.isPreparingDocumentReplacement, !reader.isRenderSnapshotDetached else {
            items.removeAll()
            isHidden = true
            return
        }
        let snapshot = reader.renderSnapshot.withLock { $0 }
        let visible = reader.visiblePages
        // 快照可以提前排版跳转目标，屏幕图层只画 PDFKit 实际显示的页面。
        let pages = visible.isEmpty ? [reader.currentPage].compactMap { $0 } : visible
        let selected = reader.selectedTextBox.map(ObjectIdentifier.init)
        let drag = reader.textBoxDrag
        inverted = snapshot.background == PDFPageBackgroundColor.black.rawValue
        var nextItems: [Item] = []
        for page in pages where page.document === reader.document {
            guard let pageContent = snapshot.pages[ObjectIdentifier(page)], !pageContent.textBoxes.isEmpty else { continue }
            let origin = convert(reader.convert(CGPoint.zero, from: page), from: reader)
            let x = convert(reader.convert(CGPoint(x: 1, y: 0), from: page), from: reader)
            let y = convert(reader.convert(CGPoint(x: 0, y: 1), from: page), from: reader)
            let transform = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                              c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
            let clip = pageContent.bounds.applying(transform).intersection(bounds)
            guard !clip.isEmpty else { continue }
            for box in pageContent.textBoxes {
                let offset = drag.flatMap { ObjectIdentifier($0.annotation) == box.id ? $0.offset : nil } ?? .zero
                let shifted = transform.translatedBy(x: offset.x, y: offset.y)
                let frame = box.drawing.bounds.applying(shifted).standardized
                guard frame.intersects(clip) else { continue }
                nextItems.append(Item(drawing: box.drawing, transform: shifted, frame: frame, pageClip: clip,
                                      selected: box.id == selected))
            }
        }
        // 同时擦掉旧位置和画出新位置。这里只刷新文本层受影响的区域。
        let dirty = (items + nextItems).reduce(CGRect.null) { $0.union($1.frame.intersection($1.pageClip)) }
        items = nextItems
        if isHidden != items.isEmpty { isHidden = items.isEmpty }
        if let item = items.last(where: \.selected), drag == nil, reader.activeType == .none, !reader.isFormFilling,
           reader.textBoxPlacement == nil, reader.document?.allowsCommenting == true {
            let x = max(bounds.minX, min(bounds.maxX - 20, item.frame.maxX - 10))
            let y = max(bounds.minY, min(bounds.maxY - 20, item.frame.maxY - 10))
            removeButton.frame = CGRect(x: x, y: y, width: 20, height: 20)
            removeButton.isHidden = false
        } else {
            removeButton.isHidden = true
        }
        if !items.isEmpty { setNeedsDisplay(dirty.insetBy(dx: -2, dy: -2).intersection(bounds)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        for item in items where dirtyRect.intersects(item.frame.insetBy(dx: -2, dy: -2)) {
            context.saveGState()
            context.clip(to: item.pageClip)
            if item.selected {
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(2)
                context.stroke(item.frame.insetBy(dx: 0.75, dy: 0.75))
            }
            context.concatenate(item.transform)
            item.drawing.draw(in: context, inverted: inverted)
            context.restoreGState()
        }
    }

    @objc private func removeSelected() { reader?.deleteSelectedTextBox() }
}
