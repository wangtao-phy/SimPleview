import AppKit

/// 本应用的阅读菜单由原生 NSMenu 拥有，不经过 Settings 场景的命令缓存。
/// 系统的应用菜单、窗口菜单和服务菜单继续由系统管理。
extension ReaderCommandRouter {
    func installMenus() {
        guard let main = NSApp.mainMenu else { return }
        sectionsByMenu.removeAll()
        func menu(_ key: String, aliases: [String], sections: [[ShortcutAction]]) -> NSMenu {
            let title = L.s(key, currentLanguage)
            let root = main.items.first { aliases.contains($0.title) }
                ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if root.menu == nil { main.insertItem(root, at: min(main.items.count, 1 + sectionsByMenu.count)) }
            let menu = NSMenu(title: title)
            root.submenu = menu
            for (index, section) in sections.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                for action in section {
                    let item = NSMenuItem(title: L.s(action.definition.title, currentLanguage), action: nil, keyEquivalent: "")
                    item.identifier = NSUserInterfaceItemIdentifier("simpleview.command." + action.rawValue)
                    menu.addItem(item)
                }
            }
            sectionsByMenu.append(root)
            return menu
        }
        let file = menu("File", aliases: ["File", "文件"], sections: [
            [.newDocument, .open], [.save, .burnIn], [.revealInFinder, .closeWindow], [.printDocument]
        ])
        let recent = NSMenuItem(title: L.s("Open Recent", currentLanguage), action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: recent.title)
        recent.submenu?.delegate = self
        recent.identifier = NSUserInterfaceItemIdentifier("simpleview.recent")
        file.insertItem(recent, at: 2)
        let edit = menu("Edit", aliases: ["Edit", "编辑"], sections: [
            [.undo, .redo], [.rotateLeft, .rotateRight, .toggleAnnotations, .signature],
            [.highlight, .underline, .strikeout, .none, .ink]
        ])
        for (offset, entry) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")].enumerated() {
            let item = NSMenuItem(title: L.s(entry.0, currentLanguage), action: Selector(entry.1), keyEquivalent: entry.2)
            item.keyEquivalentModifierMask = .command
            item.identifier = NSUserInterfaceItemIdentifier("simpleview.standard." + entry.0)
            edit.insertItem(item, at: 3 + offset)
        }
        edit.insertItem(.separator(), at: 7)
        let view = menu("View", aliases: ["View", "显示", "视图"], sections: [
            [.toggleLeftSidebar, .toggleRightSidebar], [.goBack, .previousPage, .nextPage],
            [.zoomIn, .zoomOut, .actualSize, .fitPage], [.compareView, .slideshow, .search]
        ])
        view.addItem(.separator())
        let toolbar = NSMenuItem(title: L.s("Customize Toolbar...", currentLanguage), action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        toolbar.identifier = NSUserInterfaceItemIdentifier("simpleview.standard.Customize Toolbar...")
        view.addItem(toolbar)
        let fullscreen = NSMenuItem(title: L.s("Toggle Full Screen", currentLanguage), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        fullscreen.identifier = NSUserInterfaceItemIdentifier("simpleview.standard.Toggle Full Screen")
        view.addItem(fullscreen)
        view.addItem(.separator())
        let language = NSMenuItem(title: L.s("Switch Language", currentLanguage), action: nil, keyEquivalent: "")
        language.identifier = NSUserInterfaceItemIdentifier("simpleview.language")
        language.submenu = NSMenu(title: language.title)
        for value in AppLanguage.allCases {
            let item = NSMenuItem(title: value.displayName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value.rawValue
            language.submenu?.addItem(item)
        }
        view.addItem(language)
        _ = menu("Reading Tools", aliases: ["Reading Tools", "阅读工具"], sections: [
            [.windowManagement, .pomodoro, .eyeCare, .todo], [.toggleAIChat, .openInBrowser, .history, .authors]
        ])
        if let appMenu = main.items.first?.submenu,
           !appMenu.items.contains(where: { $0.identifier?.rawValue == "simpleview.standard.Check for Updates..." }) {
            let item = NSMenuItem(title: L.s("Check for Updates...", currentLanguage), action: #selector(checkUpdates(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier("simpleview.standard.Check for Updates...")
            let position = appMenu.items.firstIndex { $0.keyEquivalent == "," }.map { $0 + 1 } ?? 1
            appMenu.insertItem(item, at: min(position, appMenu.numberOfItems))
        }
        refreshMenus()
    }
}
