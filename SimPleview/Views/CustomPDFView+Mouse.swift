#if os(macOS)
import SwiftUI
import PDFKit
import Combine

extension CustomPDFView {

    override func mouseDown(with event: NSEvent) {

        // [关键修复：焦点抢占] 当从侧边栏或悬浮窗点击进来时，PDFView 必须夺回 FirstResponder 身份，否则后续的 Backspace 键盘事件(keyDown) 会被系统丢弃！
        self.window?.makeFirstResponder(self)
        
        // --- 拦截手绘模式 ---
        if self.activeType == .ink {
            let point = self.convert(event.locationInWindow, from: nil)
            if let page = self.page(for: point, nearest: true) {
                let pagePoint = self.convert(point, to: page)
                let path = NSBezierPath()
                path.move(to: pagePoint)
                
                let batchID = "B-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
                
                self.currentDrawingPath = path
                self.currentDrawingPage = page
                self.currentDrawingBatchID = batchID
                
                self._threadSafeDrawingPath = path.copy() as? NSBezierPath
                self._threadSafeDrawingPage = page
                
                self.needsDisplay = true
                return
            }
        }
        // --- 手绘模式拦截结束 ---
        
        guard event.type == .leftMouseDown else {
            super.mouseDown(with: event)
            return
        }
        
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard page(for: viewPoint, nearest: false) != nil else {
            super.mouseDown(with: event)
            return
        }
        
        // 【关键修复】必须将事件传递给父类 PDFView，否则用户将完全无法选中文本或拖拽！
        super.mouseDown(with: event)
    }
    

    override func mouseDragged(with event: NSEvent) {
        if self.activeType == .ink,
           let path = self.currentDrawingPath,
           let page = self.currentDrawingPage {
            
            let point = self.convert(event.locationInWindow, from: nil)
            let pagePoint = self.convert(point, to: page)
            
            path.line(to: pagePoint)
            self._threadSafeDrawingPath = path.copy() as? NSBezierPath
            self.needsDisplay = true
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) { 
        // --- 手绘模式抬起处理 ---
        if self.activeType == .ink,
           let path = self.currentDrawingPath,
           let page = self.currentDrawingPage,
           let batchID = self.currentDrawingBatchID {
            
            let point = self.convert(event.locationInWindow, from: nil)
            let pagePoint = self.convert(point, to: page)
            path.line(to: pagePoint)
            
            // [核心修复] macOS PDFKit 存在严重的系统级 Bug：直接调用 `annot.add(NSBezierPath)` 创建 `.ink` 标注
            // 会在底层触发 `Cannot save value for annotation key: /InkList. Invalid type.` 错误，导致画笔路径无法保存且立刻消失！
            // 为了完美解决此问题，我们绕过原生路径添加，将坐标数据以字符串形式序列化，存入自定义的 PDF 属性中！
            let expandedBounds = path.bounds.insetBy(dx: -2, dy: -2)
            let annot = PDFAnnotation(bounds: expandedBounds, forType: .ink, withProperties: nil)
            annot.color = self.manager?.pendingColorOverride ?? self.inkColor
            annot.userName = batchID
            
            let border = PDFBorder()
            border.lineWidth = self._threadSafeLineWidth
            annot.border = border
            
            // 将真实坐标序列化（保持在 page 坐标系下，无需使用 transform，防止后续缩放错位）
            var pointsStr = ""
            for i in 0..<path.elementCount {
                var pts = [NSPoint](repeating: .zero, count: 3)
                let type = path.element(at: i, associatedPoints: &pts)
                if type == .moveTo || type == .lineTo {
                    pointsStr += "\(pts[0].x),\(pts[0].y);"
                }
            }
            
            // 利用 PDFKit 原生字典机制，植入我们的自定义键值！这个字段会随着 PDF 被永久保存！
            annot.setValue(pointsStr, forAnnotationKey: PDFAnnotationKey(rawValue: "/SimPlePath"))
            
            page.addAnnotation(annot)
            
            self.currentDrawingPath = nil
            self.currentDrawingPage = nil
            self.currentDrawingBatchID = nil
            self._threadSafeDrawingPath = nil
            self._threadSafeDrawingPage = nil
            
            if let doc = page.document {
                let index = doc.index(for: page)
                self.manager?.batchStack.append(.annotation(batchID: batchID, pageIndices: [index]))
                
                annot.modificationDate = Date()
                self.manager?.pendingColorOverride = nil
                
                self.onSaveRequired?() // 触发脏标记
                
                // [核心修复] 既然下面发了 PDFRefreshAnnotations 广播让全局重新扫描页面，
                // 这里就不能再做 allAnnotations.append()，否则会出现 O(1) 增量与 O(N) 扫描的竞态重复！
                NotificationCenter.default.post(name: NSNotification.Name("PDFRefreshAnnotations"), object: nil)
            }
            
            self.needsDisplay = true
            self.onMouseUp?()
            return
        }
        // --- 手绘模式拦截结束 ---

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
        
        // 我们关心的批注类型（包括系统 Markup 产生的签名 Stamp）
        let supportedTypes: Set<String> = ["highlight", "underline", "strikeout", "ink", "stamp", "freetext", "square", "circle", "line"]
        let clickRect = CGRect(x: pagePoint.x - 2, y: pagePoint.y - 2, width: 4, height: 4)
        
        // 获取当前页所有支持的批注（利用 reversed 惰性遍历，杜绝 filter 造成的数组内存分配开销）
        let annotations = page.annotations.reversed()
        
        // 1. 优先检测是否点中了“当前选中批注”的【边框】或【右下角图标】
        // 图标的位置会向下凸出 bounds，全局惰性扫描保证图标不会被漏掉
        if let selectedBatchID = self.currentSelectedBatchID {
            if let borderHit = annotations.first(where: { 
                supportedTypes.contains(($0.type ?? "").lowercased()) && 
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
            supportedTypes.contains(($0.type ?? "").lowercased()) && 
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
