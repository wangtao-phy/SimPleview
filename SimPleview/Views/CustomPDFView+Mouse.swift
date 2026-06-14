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
                
                // 如果之前有草稿且和当前落笔页面不同，立刻结账
                if let draftPage = self.draftInkPage, draftPage != page {
                    self.commitDraftInk()
                }
                
                let pagePoint = self.convert(point, to: page)
                let path = NSBezierPath()
                path.move(to: pagePoint)
                
                if self.currentDrawingBatchID == nil {
                    self.currentDrawingBatchID = "B-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
                }
                
                self.currentDrawingPath = path
                self.currentDrawingPage = page
                
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
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseDown(with: event)
            return
        }
        
        let pagePoint = convert(viewPoint, to: page)
        
        // --- 签名缩放与拖拽拦截 ---
        var hitSignatureForMove: PDFAnnotation? = nil
        
        let visualInset: CGFloat = 8.0 / self.scaleFactor // 屏幕上的 8 像素裕量
        
        for annot in page.annotations where (annot.userName ?? "").hasPrefix("S-") {
            let generousBounds = annot.bounds.insetBy(dx: -visualInset, dy: -visualInset)
            
            // 1. 如果是当前选中的签名，先检查四个缩放手柄
            if annot.userName == self.currentSelectedBatchID {
                let handleSize: CGFloat = 16.0 / self.scaleFactor // 屏幕上的 16 像素热区
                let hitRects = [
                    0: NSRect(x: generousBounds.minX - handleSize/2, y: generousBounds.minY - handleSize/2, width: handleSize, height: handleSize),
                    1: NSRect(x: generousBounds.maxX - handleSize/2, y: generousBounds.minY - handleSize/2, width: handleSize, height: handleSize),
                    2: NSRect(x: generousBounds.minX - handleSize/2, y: generousBounds.maxY - handleSize/2, width: handleSize, height: handleSize),
                    3: NSRect(x: generousBounds.maxX - handleSize/2, y: generousBounds.maxY - handleSize/2, width: handleSize, height: handleSize)
                ]
                
                for (corner, rect) in hitRects {
                    if rect.contains(pagePoint) {
                        // 进入缩放模式
                        self.resizingAnnotation = annot
                        self.resizeHandleCorner = corner
                        self.resizeStartBounds = annot.bounds
                        self.resizeStartMouse = event.locationInWindow
                        return // 彻底拦截，不传递给 super
                    }
                }
            }
            
            // 2. 检查是否点中了签名的主体（准备拖拽移动）
            if generousBounds.contains(pagePoint) {
                hitSignatureForMove = annot
                // 我们不 break，因为后面的批注在 z-index 上可能更高
            }
        }
        
        if let annotToMove = hitSignatureForMove {
            // 如果还没选中，先选中
            if self.currentSelectedBatchID != annotToMove.userName {
                self.currentSelectedBatchID = annotToMove.userName
                onAnnotationSelected?(annotToMove)
                self.currentPopover?.close()
                self.setNeedsDisplay(self.bounds)
            }
            
            // 进入移动模式 (corner 为 nil 代表移动)
            self.resizingAnnotation = annotToMove
            self.resizeHandleCorner = nil
            self.resizeStartBounds = annotToMove.bounds
            self.resizeStartMouse = event.locationInWindow
            return // 拦截
        }
        // --- 签名缩放与拖拽拦截结束 ---
        
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
            
            // [性能优化] 只重绘线条所在的矩形区域（适当扩大 10 像素包容笔触宽度），避免全屏重绘导致 CPU 飙升
            let dirtyRect = self.convert(path.bounds, from: page).insetBy(dx: -10, dy: -10)
            self.setNeedsDisplay(dirtyRect)
            return
        }
        // --- 签名缩放与拖拽处理 ---
        if let annot = self.resizingAnnotation, let page = annot.page {
            let startPagePoint = self.convert(self.resizeStartMouse, to: page)
            let currentPagePoint = self.convert(event.locationInWindow, to: page)
            let dx = currentPagePoint.x - startPagePoint.x
            let dy = currentPagePoint.y - startPagePoint.y
            
            var newBounds = self.resizeStartBounds
            
            if let corner = self.resizeHandleCorner {
                let aspect = self.resizeStartBounds.width / self.resizeStartBounds.height
                // 以 dx 变化为主轴来决定缩放比例，保持长宽比
                switch corner {
                case 0: // Bottom Left (minX, minY)
                    let newWidth = max(20, self.resizeStartBounds.width - dx)
                    let newHeight = newWidth / aspect
                    newBounds.size = CGSize(width: newWidth, height: newHeight)
                    newBounds.origin.x = self.resizeStartBounds.maxX - newWidth
                    newBounds.origin.y = self.resizeStartBounds.maxY - newHeight
                case 1: // Bottom Right (maxX, minY)
                    let newWidth = max(20, self.resizeStartBounds.width + dx)
                    let newHeight = newWidth / aspect
                    newBounds.size = CGSize(width: newWidth, height: newHeight)
                    newBounds.origin.y = self.resizeStartBounds.maxY - newHeight
                case 2: // Top Left (minX, maxY)
                    let newWidth = max(20, self.resizeStartBounds.width - dx)
                    let newHeight = newWidth / aspect
                    newBounds.size = CGSize(width: newWidth, height: newHeight)
                    newBounds.origin.x = self.resizeStartBounds.maxX - newWidth
                case 3: // Top Right (maxX, maxY)
                    let newWidth = max(20, self.resizeStartBounds.width + dx)
                    let newHeight = newWidth / aspect
                    newBounds.size = CGSize(width: newWidth, height: newHeight)
                default: break
                }
            } else {
                // 拖拽移动模式
                newBounds.origin.x += dx
                newBounds.origin.y += dy
            }
            
            annot.bounds = newBounds
            self.setNeedsDisplay(self.bounds)
            return
        }
        // --- 签名缩放与拖拽处理结束 ---
        
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) { 
        // --- 签名缩放结束处理 ---
        if self.resizingAnnotation != nil {
            self.resizingAnnotation = nil
            self.resizeHandleCorner = nil
            
            // 触发可能的状态保存或刷新
            self.onMouseUp?()
            return
        }
        // --- 签名缩放结束处理完毕 --- 
        // --- 手绘模式抬起处理 ---
        if self.activeType == .ink,
           let path = self.currentDrawingPath,
           let page = self.currentDrawingPage {
            
            let point = self.convert(event.locationInWindow, from: nil)
            let pagePoint = self.convert(point, to: page)
            path.line(to: pagePoint)
            
            // 误触检测：如果整个线条极短（点了一下没拖动），直接丢弃
            if path.bounds.width > 2 || path.bounds.height > 2 || path.elementCount > 3 {
                self.draftInkPaths.append(path)
                self.draftInkPage = page
                self._threadSafeDraftInkPaths = self.draftInkPaths
            }
            
            self.currentDrawingPath = nil
            self.currentDrawingPage = nil
            self._threadSafeDrawingPath = nil
            self._threadSafeDrawingPage = nil
            
            let dirtyRect = self.convert(path.bounds, from: page).insetBy(dx: -10, dy: -10)
            self.setNeedsDisplay(dirtyRect)
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
        if let selectedBatchID = self.currentSelectedBatchID, !selectedBatchID.hasPrefix("S-") {
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
    
    override func resignFirstResponder() -> Bool {
        self.commitDraftInk()
        return super.resignFirstResponder()
    }
    
    // MARK: - 墨迹多笔划成组结账逻辑
    func commitDraftInk() {
        guard !self.draftInkPaths.isEmpty, let page = self.draftInkPage, let batchID = self.currentDrawingBatchID else {
            return
        }
        
        var combinedBounds = self.draftInkPaths[0].bounds
        for p in self.draftInkPaths.dropFirst() {
            combinedBounds = combinedBounds.union(p.bounds)
        }
        
        let expandedBounds = combinedBounds.insetBy(dx: -2, dy: -2)
        let annot = PDFAnnotation(bounds: expandedBounds, forType: .ink, withProperties: nil)
        annot.color = self.manager?.pendingColorOverride ?? self.inkColor
        annot.userName = batchID
        
        let border = PDFBorder()
        border.lineWidth = self._threadSafeLineWidth
        annot.border = border
        
        // 将真实坐标序列化（保持在 page 坐标系下，无视缩放）
        // 格式升级: M,x,y;L,x,y;
        var pointsStr = ""
        for p in self.draftInkPaths {
            for i in 0..<p.elementCount {
                var pts = [NSPoint](repeating: .zero, count: 3)
                let type = p.element(at: i, associatedPoints: &pts)
                if type == .moveTo {
                    pointsStr += "M,\(pts[0].x),\(pts[0].y);"
                } else if type == .lineTo {
                    pointsStr += "L,\(pts[0].x),\(pts[0].y);"
                }
            }
        }
        
        // [严重恶性 Bug 修复：32KB 字符串极限截断导致的白屏毁坏 PDF]
        // 由于我们将多笔画作合并为一个批注，导致其序列化后的字符串轻易突破 PDF 规范中对于 Dictionary String 的绝对物理极限 (32,767 bytes)。
        // 苹果底层的 CoreGraphics 遇到超限字符串时，可能会强行截断，这在增量保存时会导致整个页面的 /Contents 流被破坏，从而导致页面不可逆转的白屏！
        // 解法：按 30,000 个字符为一块进行物理切分，分别存入 /SimPlePath, /SimPlePath1, /SimPlePath2...
        
        let chunkSize = 30000
        var chunkIndex = 0
        var currentIndex = pointsStr.startIndex
        
        while currentIndex < pointsStr.endIndex {
            let nextIndex = pointsStr.index(currentIndex, offsetBy: chunkSize, limitedBy: pointsStr.endIndex) ?? pointsStr.endIndex
            let chunk = String(pointsStr[currentIndex..<nextIndex])
            
            let keyStr = chunkIndex == 0 ? "/SimPlePath" : "/SimPlePath\(chunkIndex)"
            annot.setValue(chunk, forAnnotationKey: PDFAnnotationKey(rawValue: keyStr))
            
            currentIndex = nextIndex
            chunkIndex += 1
        }
        
        page.addAnnotation(annot)
        
        if let doc = page.document {
            let index = doc.index(for: page)
            self.manager?.batchStack.append(.annotation(batchID: batchID, pageIndices: [index]))
            
            annot.modificationDate = Date()
            self.manager?.pendingColorOverride = nil
            
            self.onSaveRequired?() // 触发脏标记
            NotificationCenter.default.post(name: NSNotification.Name("PDFRefreshAnnotations"), object: nil)
        }
        
        // 清理草稿
        self.draftInkPaths = []
        self.draftInkPage = nil
        self._threadSafeDraftInkPaths = []
        self.currentDrawingBatchID = nil
        self.needsDisplay = true
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
