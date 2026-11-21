import AppKit
import PDFKit

/// 只在定位与编辑期间记录页面。换文档后，旧页面上的草稿不能写入新文档。
struct PDFTextBoxTarget: Identifiable {
    let id = UUID()
    weak var page: PDFPage?
    let point: CGPoint
    var annotation: PDFAnnotation? = nil
}

struct PDFTextBoxDrag {
    let annotation: PDFAnnotation
    let page: PDFPage
    let start: CGPoint
    var offset = CGPoint.zero
}

extension AppState {
    var canInsertTextBox: Bool {
        guard !isClosed, let document = pdfView.document else { return false }
        return !document.isLocked && document.allowsCommenting && document.pageCount > 0
    }

    func toggleTextBoxPlacement() {
        if isPlacingTextBox {
            pdfView.finishTextBoxPlacement()
            return
        }
        guard canInsertTextBox, pdfView.formSession.commit() else { return }
        pdfView.commitDraftInk()
        isFormFilling = false
        activeType = .none
        pdfView.activeType = .none
        selectedAnnotation = nil
        pdfView.currentSelectedBatchID = nil
        pdfView.clearTextBoxInteraction()
        pdfView.clearSelection()
        pdfView.cleanupMenuObservers()

        isPlacingTextBox = true
        pdfView.textBoxPlacement = { [weak self] target in
            self?.isPlacingTextBox = false
            if let target { self?.textBoxTarget = target }
        }
        pdfView.window?.makeFirstResponder(pdfView)
    }

    func saveTextBox(_ text: String, font: NSFont, color: NSColor, at target: PDFTextBoxTarget) -> Bool {
        guard canInsertTextBox, let document = pdfView.document, let page = target.page,
              page.document === document else { return false }
        let index = document.index(for: page)
        // 编辑面板打开期间可能发生重载或撤销；草稿只允许替换仍在原页的文本框。
        let previous = target.annotation
        guard index != NSNotFound else { return false }
        if let previous, previous.page !== page || !previous.isAppTextBox { return false }
        guard let annotation = PDFAnnotation.textBox(text, font: font, color: color, at: target.point,
                                                     within: page.bounds(for: pdfView.displayBox),
                                                     rotation: page.rotation) else { return false }
        // 先关掉 PDFKit 的原生外观再挂入页面。屏幕显示只由文本框视图负责。
        if PDFTextBoxDrawing.capture(annotation, rotation: page.rotation, reusing: nil) != nil {
            StandardInk.hideNativeAppearance(annotation)
        }
        if let previous {
            // 重建原生外观并保留标识。撤销时可以完整恢复文字、位置及样式。
            if let id = previous.userName, !id.isEmpty { annotation.userName = id }
            annotationManager.replaceAnnotations([previous], with: [annotation], on: page)
            annotationManager.record(.replaceAnnotations(current: [annotation], previous: [previous], pageIndex: index))
        } else {
            page.addAnnotation(annotation)
            if let id = annotation.userName {
                annotationManager.record(.annotation(batchID: id, pageIndices: [index]))
            }
        }
        thumbnailManager.invalidateThumbnail(at: index)
        isDirty = true
        pdfView.selectedTextBox = annotation
        pdfView.annotationsChanged(on: page)
        pdfView.publishRenderSnapshot()
        pdfView.invalidatePageContent(page)
        return true
    }

    func openTextBox(_ annotation: PDFAnnotation) {
        guard canInsertTextBox, annotation.isAppTextBox,
              let page = annotation.page, page.document === pdfView.document else { return }
        pdfView.selectedTextBox = annotation
        pdfView.textBoxOverlay?.refresh()
        let transform = PDFAnnotation.textBoxUprightTransform(rotation: page.rotation)
        let rect = annotation.bounds.applying(transform)
        let point = CGPoint(x: rect.minX, y: rect.maxY).applying(transform.inverted())
        textBoxTarget = PDFTextBoxTarget(page: page, point: point, annotation: annotation)
    }
}

extension CustomPDFView {
    func beginTextBoxDrag(at point: CGPoint, with event: NSEvent) -> Bool {
        guard !isFormFilling, activeType == .none, textBoxPlacement == nil,
              document?.allowsCommenting == true, let box = textBox(at: point), let page = box.page else { return false }
        resetLinkPreview()
        if let window, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window?.makeFirstResponder(self)
        clearSelection()
        if currentSelectedBatchID != nil {
            currentSelectedBatchID = nil
            onAnnotationSelected?(nil)
        }
        selectedTextBox = box
        if event.clickCount > 1, let onTextBoxEdit {
            consumesFormMouseGesture = true
            onTextBoxEdit(box)
        } else {
            textBoxDrag = PDFTextBoxDrag(annotation: box, page: page, start: convert(point, to: page))
        }
        textBoxOverlay?.refresh()
        return true
    }

    func updateTextBoxDrag(at point: CGPoint, finished: Bool) -> Bool {
        guard var drag = textBoxDrag else { return false }
        guard let document, drag.page.document === document, drag.annotation.page === drag.page else {
            clearTextBoxInteraction()
            return true
        }
        let current = convert(point, to: drag.page)
        let dx = current.x - drag.start.x, dy = current.y - drag.start.y
        guard dx.isFinite, dy.isFinite else {
            clearTextBoxInteraction()
            return true
        }
        let original = drag.annotation.bounds
        if hypot(dx, dy) * scaleFactor >= 3 || drag.offset != .zero {
            let limit = drag.page.bounds(for: displayBox)
            let x = min(max(original.minX + dx, limit.minX), max(limit.minX, limit.maxX - original.width))
            let y = min(max(original.minY + dy, limit.minY), max(limit.minY, limit.maxY - original.height))
            drag.offset = CGPoint(x: x - original.minX, y: y - original.minY)
        }
        if finished {
            textBoxDrag = nil
            let index = document.index(for: drag.page)
            // 拖动时只移动预览。松手仍须确认页属于当前文档，再记一次撤销和保存。
            if drag.offset != .zero, index != NSNotFound, document.allowsCommenting, let manager {
                let moved = original.offsetBy(dx: drag.offset.x, dy: drag.offset.y)
                manager.record(.moveTextBox(drag.annotation, bounds: original))
                drag.annotation.bounds = moved
                publishRenderSnapshot()
                onAnnotationPagesChanged?([index])
                onSaveRequired?()
            }
        } else {
            textBoxDrag = drag
        }
        textBoxOverlay?.refresh()
        return true
    }

    func clearTextBoxInteraction() {
        guard selectedTextBox != nil || textBoxDrag != nil else { return }
        textBoxDrag = nil
        selectedTextBox = nil
        textBoxOverlay?.refresh()
    }

    @discardableResult func deleteSelectedTextBox() -> Bool {
        guard let box = selectedTextBox, let page = box.page, page.document === document,
              document?.allowsCommenting == true, let onTextBoxDelete else { return false }
        // 侧栏跳页和滚动会保留选中引用；Delete 只能作用于视口里仍可见的文本框。
        guard visiblePages.contains(where: { $0 === page }),
              visibleRect.intersects(convert(box.bounds, from: page)) else {
            clearTextBoxInteraction()
            return false
        }
        clearTextBoxInteraction()
        onTextBoxDelete(box)
        return true
    }

    func textBox(at viewPoint: CGPoint) -> PDFAnnotation? {
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let point = convert(viewPoint, to: page)
        return page.annotations.reversed().first {
            $0.isAppTextBox && ($0.shouldDisplay || StandardInk.isScreenHidden($0)) && $0.bounds.contains(point)
        }
    }

    func placeTextBox(at viewPoint: CGPoint) -> Bool {
        guard textBoxPlacement != nil, let page = page(for: viewPoint, nearest: false),
              let document, page.document === document, document.allowsCommenting else { return false }
        finishTextBoxPlacement(PDFTextBoxTarget(page: page, point: convert(viewPoint, to: page)))
        return true
    }

    func finishTextBoxPlacement(_ target: PDFTextBoxTarget? = nil) {
        guard let complete = textBoxPlacement else { return }
        textBoxPlacement = nil
        NSCursor.arrow.set()
        complete(target)
    }
}
