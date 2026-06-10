#if os(macOS)
import SwiftUI
import PDFKit

extension CustomPDFView {
    private func hitTestSignature(pagePoint: NSPoint, annotationBounds: NSRect) -> DragMode {
        let handleSize: CGFloat = 16.0 // 容错范围扩大，方便点击
        let handleRadius = handleSize / 2.0
        
        let bottomLeft = NSRect(x: annotationBounds.minX - handleRadius, y: annotationBounds.minY - handleRadius, width: handleSize, height: handleSize)
        let bottomRight = NSRect(x: annotationBounds.maxX - handleRadius, y: annotationBounds.minY - handleRadius, width: handleSize, height: handleSize)
        let topLeft = NSRect(x: annotationBounds.minX - handleRadius, y: annotationBounds.maxY - handleRadius, width: handleSize, height: handleSize)
        let topRight = NSRect(x: annotationBounds.maxX - handleRadius, y: annotationBounds.maxY - handleRadius, width: handleSize, height: handleSize)
        
        if bottomLeft.contains(pagePoint) { return .resizingBottomLeft }
        if bottomRight.contains(pagePoint) { return .resizingBottomRight }
        if topLeft.contains(pagePoint) { return .resizingTopLeft }
        if topRight.contains(pagePoint) { return .resizingTopRight }
        
        if annotationBounds.contains(pagePoint) { return .moving }
        return .none
    }
    
    override func mouseDown(with event: NSEvent) {
        // [关键修复：焦点抢占] 当从侧边栏或悬浮窗点击进来时，PDFView 必须夺回 FirstResponder 身份，否则后续的 Backspace 键盘事件(keyDown) 会被系统丢弃！
        self.window?.makeFirstResponder(self)
        
        guard event.type == .leftMouseDown else {
            super.mouseDown(with: event)
            return
        }
        
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        
        // 1. 检查是否点中已激活的 Signature
        if let sig = activeSignature, sig.page == page {
            let mode = hitTestSignature(pagePoint: pagePoint, annotationBounds: sig.bounds)
            if mode != .none {
                dragMode = mode
                dragStartPoint = pagePoint
                dragStartBounds = sig.bounds
                return // 消费事件
            } else {
                activeSignature = nil
                self.setPlatformNeedsDisplay()
            }
        }
        
        // 2. 看看有没有点中任何一个 SignatureAnnotation
        let annotations = page.annotations.reversed()
        if let target = annotations.first(where: { $0.type == "Stamp" && hitTestSignature(pagePoint: pagePoint, annotationBounds: $0.bounds) != .none }) {
            activeSignature = target
            dragMode = hitTestSignature(pagePoint: pagePoint, annotationBounds: target.bounds)
            dragStartPoint = pagePoint
            dragStartBounds = target.bounds
            
            // 同步高亮右侧边栏
            onAnnotationSelected?(target)
            
            self.setPlatformNeedsDisplay()
            return // 消费事件
        }
        
        super.mouseDown(with: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let sig = activeSignature, dragMode != .none else {
            super.mouseDragged(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = sig.page else { return }
        let pagePoint = convert(viewPoint, to: page)
        
        let dx = pagePoint.x - dragStartPoint.x
        let dy = pagePoint.y - dragStartPoint.y
        
        var newBounds = dragStartBounds
        let aspectRatio = dragStartBounds.width / dragStartBounds.height
        
        switch dragMode {
        case .moving:
            newBounds.origin.x += dx
            newBounds.origin.y += dy
        case .resizingTopRight:
            var newWidth = max(20, dragStartBounds.width + dx)
            var newHeight = newWidth / aspectRatio
            if dragStartBounds.height + dy > newHeight {
                newHeight = max(20, dragStartBounds.height + dy)
                newWidth = newHeight * aspectRatio
            }
            newBounds.size = NSSize(width: newWidth, height: newHeight)
        case .resizingTopLeft:
            var newWidth = max(20, dragStartBounds.width - dx)
            var newHeight = newWidth / aspectRatio
            if dragStartBounds.height + dy > newHeight {
                newHeight = max(20, dragStartBounds.height + dy)
                newWidth = newHeight * aspectRatio
            }
            newBounds.origin.x = dragStartBounds.maxX - newWidth
            newBounds.size = NSSize(width: newWidth, height: newHeight)
        case .resizingBottomRight:
            var newWidth = max(20, dragStartBounds.width + dx)
            var newHeight = newWidth / aspectRatio
            if dragStartBounds.height - dy > newHeight {
                newHeight = max(20, dragStartBounds.height - dy)
                newWidth = newHeight * aspectRatio
            }
            newBounds.origin.y = dragStartBounds.maxY - newHeight
            newBounds.size = NSSize(width: newWidth, height: newHeight)
        case .resizingBottomLeft:
            var newWidth = max(20, dragStartBounds.width - dx)
            var newHeight = newWidth / aspectRatio
            if dragStartBounds.height - dy > newHeight {
                newHeight = max(20, dragStartBounds.height - dy)
                newWidth = newHeight * aspectRatio
            }
            newBounds.origin.x = dragStartBounds.maxX - newWidth
            newBounds.origin.y = dragStartBounds.maxY - newHeight
            newBounds.size = NSSize(width: newWidth, height: newHeight)
        default: break
        }
        
        sig.bounds = newBounds
        self.setPlatformNeedsDisplay()
    }
    
    override func mouseUp(with event: NSEvent) { 
        if dragMode != .none {
            dragMode = .none
            onMouseUp?()
            return
        }

        // 右键或其它点击，直接走原生
        guard event.type == .leftMouseUp else {
            super.mouseUp(with: event)
            onMouseUp?()
            return
        }
        
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseUp(with: event)
            onMouseUp?()
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        
        // 如果有选中文本说明用户在拖拽选词，正常走原生流程
        if let selection = self.currentSelection, !(selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            super.mouseUp(with: event)
            onMouseUp?()
            return
        }
        
        // 我们只关心我们需要处理的批注
        let supportedTypes = ["Highlight", "Underline", "StrikeOut", "Ink"]
        let clickRect = CGRect(x: pagePoint.x - 2, y: pagePoint.y - 2, width: 4, height: 4)
        
        // 获取当前页所有支持的批注（利用 reversed 惰性遍历，杜绝 filter 造成的数组内存分配开销）
        let annotations = page.annotations.reversed()
        
        // 1. 优先检测是否点中了“当前选中批注”的【边框】或【右下角图标】
        // 图标的位置会向下凸出 bounds，全局惰性扫描保证图标不会被漏掉
        if let selectedBatchID = self.currentSelectedBatchID {
            if let borderHit = annotations.first(where: { 
                supportedTypes.contains($0.type ?? "") && 
                $0.userName == selectedBatchID && 
                isClickOnBorder(clickPoint: pagePoint, annotationBounds: $0.bounds) 
            }) {
                // 点中了边框或图标，触发悬浮窗！
                showAnnotationPopover(for: borderHit, at: viewPoint, in: self)
                onMouseUp?()
                return
            }
        }
        
        // 2. 如果没点中边框/图标，那就看看点中了哪个标注的【内部】
        // 这里加上 10 像素的容错，方便用户选中细小的下划线
        if let targetAnnotation = annotations.first(where: { 
            supportedTypes.contains($0.type ?? "") && 
            $0.bounds.insetBy(dx: -10, dy: -10).intersects(clickRect) 
        }) {
            // 乐观更新本地选中状态
            self.currentSelectedBatchID = targetAnnotation.userName
            onAnnotationSelected?(targetAnnotation)
            self.currentPopover?.close()
            onMouseUp?()
            return
        }
        
        // 3. 既没点中边框，也没点中内部，说明点击了空白处
        // 清空当前的选中状态和悬浮窗
        self.currentSelectedBatchID = nil
        self.currentPopover?.close()
        self.currentPopover = nil
        onAnnotationSelected?(nil)
        
        super.mouseUp(with: event)
        onMouseUp?()
    }
    
    // 【核心重绘】：PDFKit 原生的渲染钩子，每当页面需要重绘时就会调用
    private func isClickOnBorder(clickPoint: NSPoint, annotationBounds: NSRect) -> Bool {
        // 边框向外扩张了 4 像素
        let box = annotationBounds.insetBy(dx: -4, dy: -4)
        
        // 判断是否点中了右下角的便签图标 (向外扩展)
        let iconRect = NSRect(x: box.maxX - 6, y: box.minY - 14, width: 20, height: 20)
        if iconRect.insetBy(dx: -1, dy: -1).contains(clickPoint) {
            return true
        }
        
        // 外圈扩展 4 像素，内圈缩小 2 像素
        return box.insetBy(dx: -4, dy: -4).contains(clickPoint) && !box.insetBy(dx: 2, dy: 2).contains(clickPoint)
    }
    
    override func keyDown(with event: NSEvent) {
        // [用户体验优化：键盘快捷键删除标注]
        // 51 是 Backspace (退格键)，117 是 Forward Delete (删除键)
        if event.keyCode == 51 || event.keyCode == 117 {
            // 新增：拦截 SignatureAnnotation 的删除
            if let sig = self.activeSignature {
                onAnnotationDeleted?(sig)
                self.activeSignature = nil
                self.setPlatformNeedsDisplay()
                return
            }
            
            // 如果当前有被选中的标注框 (选中的时候会记录它的 batchID)
            if let batchID = currentSelectedBatchID, self.document != nil {
                var targetAnnot: PDFAnnotation? = nil
                
                // 遍历当前可视的页面（极简 O(1) 优化，不再做全文档 O(N) 的死亡遍历）
                // 因为我们的删除逻辑 (deleteSelectedAnnotation) 只要拿到一个样本，就会自动删掉整个家族。
                for page in self.visiblePages {
                    if let found = page.annotations.first(where: { $0.userName == batchID }) {
                        targetAnnot = found
                        break
                    }
                }
                
                if let target = targetAnnot {
                    onAnnotationDeleted?(target) // 告诉外界：用户下令删除了！
                    
                    // 清理本地状态
                    self.currentSelectedBatchID = nil
                    self.currentPopover?.close()
                    self.currentPopover = nil
                    self.setPlatformNeedsDisplay() // 强刷画布，让选框消失
                    return // 拦截这个按键事件，不再往下传
                }
            }
        }
        
        super.keyDown(with: event) // 不是删除键，或者没选中任何东西，乖乖交给系统处理
    }
    
    // [NSPopoverDelegate 代理方法]
}
#endif
