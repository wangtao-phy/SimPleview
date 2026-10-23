import AppKit
import PDFKit

/// 一次手势强持源/目标页；PDFDestination.page 本身是弱引用，不能独自保证目标存活。
struct InternalLinkGesture {
    let document: PDFDocument
    let sourcePage: PDFPage
    let annotation: PDFAnnotation
    let targetPage: PDFPage
    let destination: PDFDestination
    let startInView: CGPoint
    let startOnPage: CGPoint
    var isSelecting = false
}

extension CustomPDFView {
    /// 链接手势在 PDFKit 内部子视图收到 down 之前接管。让原生先开始追踪、再
    /// 等待监视器的 up 并不可靠：AppKit 的嵌套事件循环不会经过 local monitor。
    /// 其余事件原样交回；不依赖 PDFKit 子视图将 mouseDown 转发给外层 PDFView。
    func startLinkTracking() {
        stopLinkTracking()
        guard let window else { return }
        linkEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.handleLinkMouseEvent(event) ?? false
            }
            return consumed ? nil : event
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
        let cancellationNotifications: [(NotificationCenter, Notification.Name, Any?)] = [
            (.default, NSApplication.didResignActiveNotification, NSApplication.shared),
            (.default, .PDFViewDocumentChanged, self),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, nil)
        ]
        for (center, name, object) in cancellationNotifications {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resetLinkPreview() }
            }
            linkTrackingObservers.append((center, token))
        }
        let resignKey = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                // 原生预览取得键盘焦点后要能选择、复制文字，不能因主窗口失焦而关掉它。
                MainActor.assumeIsolated { self?.linkMouseGesture = nil }
            }
        linkTrackingObservers.append((.default, resignKey))
        let becomeKey = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self] notification in
                let focused = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let focused,
                          focused !== self.window,
                          focused !== self.hoverPopover?.contentViewController?.view.window else { return }
                    self.resetLinkPreview()
                }
            }
        linkTrackingObservers.append((.default, becomeKey))
        refreshLinkTracking()
    }

    func stopLinkTracking() {
        if let linkEventMonitor { NSEvent.removeMonitor(linkEventMonitor) }
        linkEventMonitor = nil
        for observer in linkTrackingObservers { observer.center.removeObserver(observer.token) }
        linkTrackingObservers.removeAll()
        resetLinkPreview()
        consumesLinkMouseGesture = false
        consumesFormMouseGesture = false
    }

    /// 重新取得当前鼠标位置，不能依赖休眠前的链接对象或等待鼠标离开再进入。
    func refreshLinkTracking() {
        guard let window else { return }
        resetLinkPreview()
        consumesLinkMouseGesture = false
        window.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        guard window.isKeyWindow else { return } // 避免唤醒时替被遮住的后台窗口弹出预览。
        updateLinkHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func updateLinkHover(at point: CGPoint) {
        // 窗口级事件也包括侧栏和覆盖在 PDF 上的控件，必须按实际命中的视图过滤。
        // AppKit hitTest 使用接收视图的父坐标系，不能直接传 PDF 页坐标。
        guard !isFormFilling, activeType == .none, !consumesLinkMouseGesture,
              NSApplication.shared.isActive, ownsLinkPoint(point),
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
            self.showLinkPreviewPopover(for: annotation)
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
        guard let document, let sourcePage = annotation.page,
              sourcePage.document === document, document.index(for: sourcePage) != NSNotFound else { return nil }
        for candidate in [annotation.destination, (annotation.action as? PDFActionGoTo)?.destination].compactMap({ $0 }) {
            guard let page = candidate.page, page.document === document,
                  document.index(for: page) != NSNotFound else { continue }
            let bounds = page.bounds(for: .cropBox), point = candidate.point
            guard !bounds.isEmpty, bounds.minX.isFinite, bounds.maxX.isFinite,
                  bounds.minY.isFinite, bounds.maxY.isFinite else { continue }
            let hasX = point.x.isFinite && point.x != kPDFDestinationUnspecifiedValue
            let hasY = point.y.isFinite && point.y != kPDFDestinationUnspecifiedValue
            var fallback = CGPoint(x: bounds.minX, y: bounds.maxY)
            if !hasX && !hasY {
                // Fit 没有定位坐标，取旋转后显示的左上角；明确的 XYZ 坐标仍保留。
                let transform = page.transform(for: .cropBox)
                let displayed = bounds.applying(transform)
                fallback = CGPoint(x: displayed.minX, y: displayed.maxY).applying(transform.inverted())
            }
            let x = hasX ? min(max(point.x, bounds.minX), bounds.maxX) : fallback.x
            let y = hasY ? min(max(point.y, bounds.minY), bounds.maxY) : fallback.y
            let destination = PDFDestination(page: page, at: CGPoint(x: x, y: y))
            if candidate.zoom.isFinite && candidate.zoom > 0 && candidate.zoom != kPDFDestinationUnspecifiedValue {
                destination.zoom = candidate.zoom
            }
            return destination
        }
        return nil
    }

    func resetLinkPreview() {
        // 取消时立即释放旧文档，但保留 drag/up 的所有权，直到本次手势真正结束。
        linkMouseGesture = nil
        // 滚动会频繁经过这里。没有悬停状态时，不触发同步快照或局部重绘。
        guard hoverTask != nil || hoverPopover != nil || currentHoveredLink != nil || isHoveringLinkPreview else { return }
        hoverTask?.cancel(); hoverTask = nil
        let old = hoverPopover
        hoverPopover = nil
        isHoveringLinkPreview = false
        updateHoveredLink(nil)
        // 取消预览任务也会结束本次专属渲染进程；关闭后不保留文档或承载视图。
        old?.close()
        old?.contentViewController = nil
    }

    private func ownsLinkPoint(_ point: CGPoint) -> Bool {
        guard visibleRect.contains(point), let root = window?.contentView,
              let hit = root.hitTest(convert(point, to: root.superview)) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    /// 普通事件不改写；只有已接管的链接手势返回 true，由监视器停止再次派发。
    /// 不启动嵌套事件循环，所以文件刷新、失焦和关闭仍能及时取消本次操作。
    func handleLinkMouseEvent(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseDown {
            // 可能在窗口外抬起了鼠标。任何新点击都不继承丢失 up 的旧手势。
            linkMouseGesture = nil
            consumesLinkMouseGesture = false
        }
        if event.window === window, event.type == .leftMouseDragged || event.type == .leftMouseUp,
           consumesFormMouseGesture {
            if event.type == .leftMouseUp { consumesFormMouseGesture = false }
            return true // down 已用于打开控件，不能把无配对的 up 交给 PDFKit 清走焦点。
        }
        if event.type == .leftMouseDown { consumesFormMouseGesture = false }
        if event.window === window, formSession.ownsEditorPoint(convert(event.locationInWindow, from: nil)) {
            return false // 输入框中的定位、拖选和复制完全由 AppKit 处理。
        }
        if event.type == .leftMouseDown, event.window === window {
            let point = convert(event.locationInWindow, from: nil)
            if ownsLinkPoint(point), formSession.activateField(at: point) {
                consumesFormMouseGesture = true
                return true
            }
        }
        if isFormFilling {
            return false // 原有第三方字段继续使用原生输入，不接管链接手势。
        }
        guard let window, event.window === window else {
            if event.type == .leftMouseDown,
               event.window !== hoverPopover?.contentViewController?.view.window { resetLinkPreview() }
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .mouseMoved:
            // 在窗口外松开、休眠等情况下可能收不到 up。这里只取消已结束的手势，
            // 不用按钮全局状态计算拖动轨迹，也不需要定时轮询。
            if consumesLinkMouseGesture, NSEvent.pressedMouseButtons & 1 == 0 {
                linkMouseGesture = nil
                consumesLinkMouseGesture = false
            }
            updateLinkHover(at: point)
            return false
        case .scrollWheel:
            resetLinkPreview()
            return false
        case .leftMouseDown:
            let specialModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard activeType == .none, event.clickCount == 1,
                  event.modifierFlags.intersection(specialModifiers).isEmpty,
                  ownsLinkPoint(point), let document,
                  let page = page(for: point, nearest: false), page.displaysAnnotations,
                  let annotation = internalLink(at: convert(point, to: page), on: page),
                  let destination = linkDestination(for: annotation), let targetPage = destination.page else { return false }
            // down 不再交给 NSWindow，故在记录手势前完成原本由鼠标事件触发的窗口激活。
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            resetLinkPreview()
            window.makeFirstResponder(self)
            linkMouseGesture = InternalLinkGesture(document: document, sourcePage: page, annotation: annotation,
                targetPage: targetPage, destination: destination, startInView: point, startOnPage: convert(point, to: page))
            consumesLinkMouseGesture = true
            return true
        case .leftMouseDragged, .leftMouseUp:
            guard consumesLinkMouseGesture else { return false }
            let finished = event.type == .leftMouseUp
            defer {
                if finished {
                    linkMouseGesture = nil
                    consumesLinkMouseGesture = false
                }
            }
            guard var gesture = linkMouseGesture, activeType == .none,
                  gesture.document === document, gesture.sourcePage.document === document,
                  gesture.targetPage.document === document, gesture.annotation.page === gesture.sourcePage,
                  gesture.document.index(for: gesture.sourcePage) != NSNotFound,
                  gesture.document.index(for: gesture.targetPage) != NSNotFound else {
                linkMouseGesture = nil
                return true
            }
            let dx = point.x - gesture.startInView.x, dy = point.y - gesture.startInView.y
            gesture.isSelecting = gesture.isSelecting || dx * dx + dy * dy >= 16
            if gesture.isSelecting {
                // 与普通文字选择共用 PDFSelection 和 first responder，Cmd+C 无需 OCR。
                if let endPage = page(for: point, nearest: true), endPage.document === gesture.document {
                    let selection = gesture.document.selection(from: gesture.sourcePage, at: gesture.startOnPage,
                        to: endPage, at: convert(point, to: endPage))
                    setCurrentSelection(selection, animate: false)
                }
                linkMouseGesture = gesture
            } else if finished, ownsLinkPoint(point),
                      gesture.annotation.bounds.contains(convert(point, to: gesture.sourcePage)) {
                // 点击不等待预览、图像分析或辅助进程；只使用仍属于当前文档的目标。
                clearSelection()
                go(to: gesture.destination)
            }
            if finished { onMouseUp?() }
            return true
        default:
            return false
        }
    }
}
