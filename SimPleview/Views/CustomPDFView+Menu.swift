#if os(macOS)
import SwiftUI
import PDFKit

extension CustomPDFView {
    override func menu(for event: NSEvent) -> NSMenu? {
        // 先让系统生成它默认的那一套冗长繁琐的菜单
        guard let menu = super.menu(for: event) else { return nil }
        
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else { return menu }
        let pagePoint = convert(viewPoint, to: page)
        
        // 如果右键点在了一个批注上...
        if let annotation = page.annotation(at: pagePoint) {
            lastClickedAnnotation = annotation
            initialAnnotationColor = annotation.color
            
            // 挂一个 KVO 监听器，只要菜单里改了颜色，我就能知道
            colorObserver?.invalidate()
            colorObserver = annotation.observe(\.color, options: [.new]) { [weak self] annot, _ in
                nonisolated(unsafe) let safeAnnot = annot
                Task { @MainActor in
                    self?.syncBatchColor(for: safeAnnot)
                }
            }
            
            // 删掉系统原生的没用选项（第一组）
            while menu.items.count > 0 && (menu.items[0].title.isEmpty || menu.items[0].isSeparatorItem) {
                menu.removeItem(at: 0)
            }
            
            // 塞入我们自己漂亮可爱的多色选取菜单！
            addCustomColorMenu(to: menu, for: annotation)
            
            if let obs = menuObserver { NotificationCenter.default.removeObserver(obs) }
            menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleMenuClosed()
                }
            }
            
            // 将系统中散落的“删除”按钮的点击事件，劫持给我们的代码接管！
            hijackSystemMenu(menu, for: annotation)
        } else {
            lastClickedAnnotation = nil
            initialAnnotationColor = nil
            colorObserver = nil
        }
        return menu
    }

    private func addCustomColorMenu(to menu: NSMenu, for annotation: PDFAnnotation) {
        let colorMenu = NSMenu(title: "更改颜色")
        let colorOptions: [(String, NSColor)] = [("蓝色", .systemBlue), ("红色", .systemRed), ("黄色", .systemYellow), ("绿色", .systemGreen), ("紫色", .systemPurple)]
        
        colorOptions.forEach { name, color in
            let item = NSMenuItem(title: name, action: #selector(handleColorChange(_:)), keyEquivalent: "")
            item.target = self
            // representedObject 是用来夹带私货的，我们把这个颜色应该涂给哪个批注存在这里
            item.representedObject = ["annotation": annotation, "color": color]
            let size = NSSize(width: 12, height: 12)
            
            // 用代码画一个彩色小圆圈作为菜单图标
            item.image = NSImage(size: size, flipped: false) { rect in
                color.set()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            colorMenu.addItem(item)
        }
        
        let mainItem = NSMenuItem(title: "更改颜色", action: nil, keyEquivalent: "")
        mainItem.submenu = colorMenu
        menu.insertItem(mainItem, at: 0) // 插到菜单最顶端
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func handleColorChange(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any], let annotation = info["annotation"] as? PDFAnnotation, let color = info["color"] as? NSColor else { return }
        annotation.color = color
        syncBatchColor(for: annotation)
        onColorChanged?(color, annotation.type ?? "")
    }
    
    // 把菜单里所有字面带有“删除”意思的按钮全部没收，强制执行我们的 `handleDeleteAction`
    private func hijackSystemMenu(_ menu: NSMenu, for annotation: PDFAnnotation) {
        let deleteKeywords = Set(["delete", "remove", "删除", "移除", "清除"])
        menu.items.forEach { item in
            let title = item.title.lowercased()
            let actionDesc = item.action?.description.lowercased() ?? ""
            if deleteKeywords.contains(where: { title.contains($0) || actionDesc.contains($0) }) {
                item.target = self
                item.action = #selector(handleDeleteAction(_:))
                item.representedObject = annotation
            }
            // 递归劫持子菜单
            if let submenu = item.submenu { hijackSystemMenu(submenu, for: annotation) }
        }
    }
    
    @objc func handleDeleteAction(_ sender: NSMenuItem) {
        let annotation = (sender.representedObject as? PDFAnnotation) ?? lastClickedAnnotation
        if let annot = annotation { onAnnotationDeleted?(annot) }
    }
    
    private func handleMenuClosed() {
        if let obs = menuObserver { NotificationCenter.default.removeObserver(obs); menuObserver = nil }
        if let annot = lastClickedAnnotation, let initialColor = initialAnnotationColor, !annot.color.isEqual(initialColor) {
            syncBatchColor(for: annot)
        }
        colorObserver = nil
    }

}
#endif
