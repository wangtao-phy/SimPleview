import AppKit
import PDFKit
import os

/// 此对象只包含值和复制后的不可变 CoreGraphics 对象。允许跨执行器传递的
/// 前提是发布后不再修改路径；不得把 NSBezierPath/PDFAnnotation 放入快照。
nonisolated struct PDFRenderSnapshot: @unchecked Sendable {
    struct Stroke {
        let path: CGPath
        let color: CGColor
        let width: CGFloat
        let fill: Bool
    }
    struct Page {
        let transform: CGAffineTransform
        let bounds: CGRect
        let strokes: [Stroke]
        let noteIcons: [NoteIcon]
        var vectorInkIDs: Set<ObjectIdentifier> = []
        var scan: ScanPage? = nil
    }
    struct NoteIcon {
        let image: CGImage
        let rect: CGRect
    }
    var background = 0
    var pages: [ObjectIdentifier: Page] = [:]
}

extension CustomPDFView {
    /// PDFKit 的窗口/滚动通知可能先于内部可见页更新。合并到下一轮主队列
    /// 再取 visiblePages，避免把尚未完成布局的空列表当成最终视口。
    /// 每个视图最多排队一次，弱引用不延长窗口寿命；手绘仍同步发布快照。
    func scheduleRenderSnapshot() {
        guard window != nil, !isRenderSnapshotScheduled else { return }
        isRenderSnapshotScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRenderSnapshotScheduled = false
            guard self.window != nil else { return }
            self.publishRenderSnapshot()
        }
    }

    /// 只在主执行器收集可见页。锁仅用于一次值替换，PDFKit/绘图调用均在锁外，
    /// 避免后台瓦片等待主线程或持锁回调造成死锁。
    func publishRenderSnapshot() {
        // shouldDisplay 的更新可能引起同步重绘通知；禁止重入快照构建。
        guard !isPublishingRenderSnapshot else { return }
        isPublishingRenderSnapshot = true
        defer { isPublishingRenderSnapshot = false }
        observeRenderViewport()
        var snapshot = PDFRenderSnapshot()
        snapshot.background = _threadSafePageBackgroundColor.rawValue
        var pages = visiblePages
        for page in [draftInkPage, currentDrawingPage, currentHoveredLink?.page].compactMap({ $0 }) {
            if !pages.contains(where: { $0 === page }) { pages.append(page) }
        }
        for page in pages {
            var strokes: [PDFRenderSnapshot.Stroke] = []
            var noteIcons: [PDFRenderSnapshot.NoteIcon] = []
            var vectorInkIDs = Set<ObjectIdentifier>()
            func add(_ path: NSBezierPath, color: NSColor, width: CGFloat = 1, fill: Bool = false) {
                guard let immutable = path.cgPath.copy() else { return }
                strokes.append(.init(path: immutable, color: color.cgColor, width: width, fill: fill))
            }
            let annotations = page.displaysAnnotations ? page.annotations : []
            let selected = annotations.filter { currentSelectedBatchID != nil && $0.userName == currentSelectedBatchID }
            let lowestSelected = selected.min { $0.bounds.minY < $1.bounds.minY }
            let accent = NSColor.controlAccentColor.withAlphaComponent(0.8)
            for annotation in annotations {
                // 恢复原版已提交手绘的直接矢量绘制：草稿结账后不能只交给
                // PDFKit 的批注位图缓存。使用原始路径，在当前缩放的 CGContext
                // 上重新描边；保存仍保留标准 InkList，外部阅读器也能读到笔迹。
                if VectorInkDrawingScope.installed, StandardInk.prepareForScreen(annotation) {
                    let paths = StandardInk.pagePaths(of: annotation)
                    if !paths.isEmpty { vectorInkIDs.insert(ObjectIdentifier(annotation)) }
                    for path in paths {
                        add(path, color: StandardInk.displayColor(of: annotation), width: annotation.border?.lineWidth ?? 3)
                    }
                }
                if let id = currentSelectedBatchID, annotation.userName == id {
                    let scale = max(scaleFactor, 0.1)
                    let inset: CGFloat = id.hasPrefix("S-") ? 8 / scale : 4
                    let rect = annotation.bounds.insetBy(dx: -inset, dy: -inset)
                    add(NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4), color: accent,
                        width: id.hasPrefix("S-") ? 1.5 / scale : 1.5)
                    if id.hasPrefix("S-") {
                        let size = 8 / scale
                        for p in [rect.origin, CGPoint(x: rect.maxX, y: rect.minY),
                                  CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                            let circle = NSBezierPath(ovalIn: CGRect(x: p.x-size/2, y: p.y-size/2, width: size, height: size))
                            add(circle, color: .white, fill: true)
                            add(circle, color: accent, width: 1 / scale)
                        }
                    } else if annotation === lowestSelected, let image = selectionNoteImage() {
                        // 恢复原来的半透明 note.text 图标；多段选区只在最下面
                        // 一段显示一个。此位置与鼠标命中区域完全一致。
                        noteIcons.append(.init(image: image,
                            rect: CGRect(x: rect.maxX - 20, y: rect.minY - 20, width: 20, height: 20)))
                    }
                }
                // 旧签名仍需读取私有归一化路径；解析和缩放全部在主线程完成。
                if (annotation.userName ?? "").hasPrefix("S-") {
                    let path: CGPath?
                    if let signature = annotation as? VectorSignatureAnnotation {
                        path = signature.vectorPath
                    } else {
                        path = legacySignaturePath(annotation)
                    }
                    if let path {
                        var transform = CGAffineTransform(translationX: annotation.bounds.minX, y: annotation.bounds.minY)
                            .scaledBy(x: annotation.bounds.width, y: annotation.bounds.height)
                        if let positioned = path.copy(using: &transform) {
                            strokes.append(.init(path: positioned, color: annotation.color.cgColor, width: 0, fill: true))
                        }
                    }
                }
            }
            if let link = currentHoveredLink, link.page === page {
                add(NSBezierPath(roundedRect: link.bounds.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2),
                    color: NSColor.controlAccentColor.withAlphaComponent(0.15), fill: true)
            }
            if page.displaysAnnotations && activeType == .ink {
                if currentDrawingPage === page, let path = currentDrawingPath {
                    add(path, color: inkColor, width: _threadSafeLineWidth)
                }
                if draftInkPage === page {
                    for path in draftInkPaths { add(path, color: inkColor, width: _threadSafeLineWidth) }
                }
            }
            snapshot.pages[ObjectIdentifier(page)] = .init(transform: page.transform(for: .cropBox),
                                                           bounds: page.bounds(for: .cropBox), strokes: strokes, noteIcons: noteIcons,
                                                           vectorInkIDs: vectorInkIDs)
            // 仅优化没有普通标注的扫描页。标准标注仍交给 PDFKit，避免缓存
            // 遮挡选择、高亮或外部软件创建的外观；手绘草稿在缓存之上照常矢量绘制。
            if displayBox == .cropBox { snapshot.pages[ObjectIdentifier(page)]?.scan = ScanPage.capture(page) }
        }
        renderSnapshot.withLock { [snapshot] in $0 = snapshot }
        // 只在实际显示时预备当前页及紧邻的一页；不因打开长文档而生成整本图片。
        // 瓦片未命中仍立即走 PDFKit，后台图像就绪后供后续瓦片/回滚复用。
        if window != nil, displayBox == .cropBox, let document {
            var warming = visiblePages
            let indices = warming.map { document.index(for: $0) }.filter { $0 != NSNotFound }
            if let first = indices.min(), first > 0, let page = document.page(at: first - 1) { warming.append(page) }
            if let last = indices.max(), last + 1 < document.pageCount, let page = document.page(at: last + 1) { warming.append(page) }
            scanCache.update(pages: warming, scale: scaleFactor * (window?.backingScaleFactor ?? 2))
        }
    }

    /// SF Symbol 和 NSGraphicsContext 只在主线程使用，后台瓦片仅取得不可变
    /// CGImage。按当前缩放/屏幕像素密度生成图标，避免放大后使用低分辨率缓存。
    private func selectionNoteImage() -> CGImage? {
        let pixels = min(512, max(20, Int(ceil(20 * max(scaleFactor, 0.1) * (window?.backingScaleFactor ?? 2)))))
        let tint = NSColor.controlAccentColor.withAlphaComponent(0.85)
        if _cachedNoteIconPixels == pixels, _cachedNoteIconTint == tint, let image = _cachedNoteCGImage { return image }
        guard let symbol = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(hierarchicalColor: tint)),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        symbol.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        _cachedNoteIconPixels = pixels; _cachedNoteIconTint = tint; _cachedNoteCGImage = bitmap.cgImage
        return _cachedNoteCGImage
    }

    private func legacySignaturePath(_ annotation: PDFAnnotation) -> CGPath? {
        var chunks: [String] = []
        var bytes = 0
        for i in 0..<1024 {
            let key = i == 0 ? "/SimPlePath" : "/SimPlePath\(i)"
            guard let chunk = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: key)) as? String else { break }
            bytes += chunk.utf8.count
            guard bytes <= 8_000_000 else { return nil }
            chunks.append(chunk)
        }
        let path = CGMutablePath()
        for token in chunks.joined().split(separator: ";") {
            let c = token.split(separator: ",")
            guard c.count == 3, let x = Double(c[1]), let y = Double(c[2]), x.isFinite, y.isFinite else { continue }
            if c[0] == "M" || path.isEmpty { path.move(to: CGPoint(x: x, y: y)) }
            else if c[0] == "L" { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path.copy()
    }
}
