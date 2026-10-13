import AppKit
import PDFKit

extension CustomPDFView {
    /// PDFKit 的内部视图可能接管 mouseMoved；窗口内监视器先处理悬停，
    /// 再原样交回事件，文字选择、手绘和原生鼠标行为仍由原来的响应者处理。
    func startLinkTracking() {
        stopLinkTracking()
        guard let window else { return }
        linkEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                self.updateLinkHover(at: self.convert(event.locationInWindow, from: nil))
            }
            return event
        }
        // 只在重新激活、标签回到前台或系统唤醒时恢复追踪；不使用定时轮询。
        let notifications: [(NotificationCenter, Notification.Name, Any?)] = [
            (.default, NSApplication.didBecomeActiveNotification, NSApplication.shared),
            (.default, NSWindow.didBecomeKeyNotification, window),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, nil)
        ]
        for (center, name, object) in notifications {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLinkTracking() }
            }
            linkTrackingObservers.append((center, token))
        }
        refreshLinkTracking()
    }

    func stopLinkTracking() {
        if let linkEventMonitor { NSEvent.removeMonitor(linkEventMonitor) }
        linkEventMonitor = nil
        for observer in linkTrackingObservers { observer.center.removeObserver(observer.token) }
        linkTrackingObservers.removeAll()
        resetLinkPreview()
    }

    /// 重新取得当前鼠标位置，不能依赖休眠前的链接对象或等待鼠标离开再进入。
    func refreshLinkTracking() {
        guard let window else { return }
        resetLinkPreview()
        window.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        guard window.isKeyWindow else { return } // 避免唤醒时替被遮住的后台窗口弹出预览。
        updateLinkHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func updateLinkHover(at point: CGPoint) {
        // 窗口级事件也包括侧栏和覆盖在 PDF 上的控件，必须按实际命中的视图过滤。
        // AppKit hitTest 使用接收视图的父坐标系，不能直接传 PDF 页坐标。
        guard let window, NSApplication.shared.isActive,
              visibleRect.contains(point), let root = window.contentView,
              let hit = root.hitTest(convert(point, to: root.superview)),
              hit === self || hit.isDescendant(of: self),
              let page = page(for: point, nearest: false),
              let annotation = internalLink(at: convert(point, to: page), on: page) else {
            handleMouseLeaveLink()
            return
        }
        // 同一链接只保留一个展示任务；窗口监视器和原生回调重复到达也不重启计时。
        guard currentHoveredLink !== annotation ||
              (hoverTask == nil && hoverPopover?.isShown != true) else { return }
        hoverTask?.cancel()
        updateHoveredLink(annotation)
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.currentHoveredLink === annotation else { return }
            self.hoverTask = nil
            self.showLinkPreviewPopover(for: annotation, in: self)
        }
    }

    /// 单独命中链接，避免后来加的高亮标注挡住其下方的原始链接。
    func internalLink(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.reversed().first {
            $0.type == "Link" && $0.bounds.contains(point) && $0.url == nil && !($0.action is PDFActionURL)
        }
    }

    /// 预览与点击共用当前文档中的目标；不把 Fit/XYZ 的空坐标哨兵传给滚动引擎。
    func linkDestination(for annotation: PDFAnnotation) -> PDFDestination? {
        guard let document, annotation.page?.document === document else { return nil }
        for candidate in [annotation.destination, (annotation.action as? PDFActionGoTo)?.destination].compactMap({ $0 }) {
            guard let page = candidate.page, page.document === document else { continue }
            let bounds = page.bounds(for: .cropBox), point = candidate.point
            guard !bounds.isEmpty, bounds.minX.isFinite, bounds.maxX.isFinite,
                  bounds.minY.isFinite, bounds.maxY.isFinite else { continue }
            let x = point.x.isFinite && (bounds.minX...bounds.maxX).contains(point.x) ? point.x : bounds.minX
            let y = point.y.isFinite && (bounds.minY...bounds.maxY).contains(point.y) ? point.y : bounds.maxY
            let destination = PDFDestination(page: page, at: CGPoint(x: x, y: y))
            if candidate.zoom.isFinite && candidate.zoom > 0 { destination.zoom = candidate.zoom }
            return destination
        }
        return nil
    }

    func resetLinkPreview() {
        // 滚动会频繁经过这里。没有悬停状态时，不触发同步快照或局部重绘。
        guard hoverTask != nil || hoverPopover != nil || currentHoveredLink != nil || isHoveringLinkPreview else { return }
        hoverTask?.cancel(); hoverTask = nil
        let old = hoverPopover
        hoverPopover = nil
        isHoveringLinkPreview = false
        updateHoveredLink(nil)
        // 关闭承载视图会取消 SwiftUI .task，进而结束专属预览进程。
        old?.close()
        old?.contentViewController = nil
    }

    /// 点击直接跳转，不等待预览或文字识别；拖离链接则取消本次点击。
    func trackInternalLink(_ annotation: PDFAnnotation, on page: PDFPage) -> Bool {
        guard linkDestination(for: annotation) != nil, let window else { return false }
        resetLinkPreview()
        clearSelection()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            guard annotation.page === page, page.document === document else { return true }
            if next.type == .leftMouseUp {
                let point = convert(convert(next.locationInWindow, from: nil), to: page)
                if annotation.bounds.contains(point), let destination = linkDestination(for: annotation) {
                    go(to: destination)
                }
                return true
            }
        }
        return true
    }
}
