import SwiftUI
#if os(macOS)
import AppKit
import Combine
import UniformTypeIdentifiers

/// 在 Popover 中展示当前的窗口/标签页分组
struct TabGroupsPopoverView: View {
    @ObservedObject var registry = WindowRegistry.shared
    @State private var emptyGroups: [EmptyGroup] = []
    
    // 我们需要将分散的 controllers 按它们的 tabbedWindows 分组
    // 由于 tabbedWindows 返回的数组对于同一个 tab 组内的所有窗口都是相同的（包含它们自己），
    // 我们可以使用 tab 组中第一个窗口的 object identifier 作为组的唯一标识。
    var windowGroups: [[NSWindow]] {
        var groups: [[NSWindow]] = []
        var processedWindowIDs = Set<ObjectIdentifier>()
        
        // 过滤出真正包含我们 App 逻辑的窗口
        let appWindows = registry.controllers.compactMap { $0.window }
        
        for window in appWindows {
            let winID = ObjectIdentifier(window)
            if processedWindowIDs.contains(winID) { continue }
            
            // 获取这个窗口所在的整个 tab 组
            if let tabbed = window.tabbedWindows {
                groups.append(tabbed)
                for w in tabbed {
                    processedWindowIDs.insert(ObjectIdentifier(w))
                }
            } else {
                // 如果系统出于某种原因没有返回 tabbedWindows，将它自己作为一组
                groups.append([window])
                processedWindowIDs.insert(winID)
            }
        }
        
        return groups
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("标签页分组")
                .font(.headline)
                .padding()
            
            Divider()
            
            if windowGroups.isEmpty && emptyGroups.isEmpty {
                Text("暂无打开的文档")
                    .foregroundColor(.gray)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(windowGroups.enumerated()), id: \.element.first!.hashValue) { index, group in
                            WindowGroupSection(windows: group, groupIndex: index + 1)
                        }
                        
                        ForEach(Array(emptyGroups.enumerated()), id: \.element.id) { index, emptyGroup in
                            EmptyGroupSection(emptyGroup: emptyGroup, groupIndex: windowGroups.count + index + 1) { updatedGroup in
                                if let idx = emptyGroups.firstIndex(where: { $0.id == updatedGroup.id }) {
                                    emptyGroups[idx] = updatedGroup
                                }
                            } onRemove: {
                                emptyGroups.removeAll { $0.id == emptyGroup.id }
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 800)
            }
            
            Divider()
            
            Button(action: {
                emptyGroups.append(EmptyGroup())
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "plus")
                    Text("新建分组")
                    Spacer()
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(NSColor.controlBackgroundColor))
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .frame(width: 300)
    }
}

struct WindowGroupSection: View {
    let windows: [NSWindow]
    let groupIndex: Int
    @State private var customGroupName: String = ""
    @State private var isEditingName: Bool = false
    
    // 我们用 UserDefaults 来保存自定义分组名称，键是窗口的某个特征
    // 但因为每次拖拽导致窗口组合可能变动，我们需要一个稳定的 Key。
    // 为了简单，我们使用第一个窗口的 windowNumber 作为持久化 Key（它在窗口生命周期内存活）。
    private var groupKey: String {
        if let firstWindow = windows.first {
            return "CustomGroupName_\(firstWindow.windowNumber)"
        }
        return ""
    }
    
    private var defaultGroupTitle: String {
        "未命名分组 \(groupIndex)"
    }
    
    var groupTitle: String {
        if !customGroupName.isEmpty { return customGroupName }
        let savedName = UserDefaults.standard.string(forKey: groupKey)
        return savedName?.isEmpty == false ? savedName! : defaultGroupTitle
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "square.grid.2x2")
                    .foregroundColor(.accentColor)
                
                if isEditingName {
                    TextField("输入分组名称...", text: $customGroupName, onCommit: {
                        UserDefaults.standard.set(customGroupName, forKey: groupKey)
                        isEditingName = false
                    })
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(maxWidth: .infinity)
                } else {
                    Text(groupTitle)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { // 双击重命名
                            customGroupName = groupTitle == defaultGroupTitle ? "" : groupTitle
                            isEditingName = true
                        }
                }
                
                Spacer()
                
                if !isEditingName {
                    Button(action: {
                        customGroupName = groupTitle == defaultGroupTitle ? "" : groupTitle
                        isEditingName = true
                    }) {
                        Image(systemName: "pencil")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            
            VStack(spacing: 2) {
                ForEach(windows, id: \.hashValue) { window in
                    TabItemView(window: window)
                }
            }
            // 允许把 tab 拖回空分组头部（虽然很少会有空分组，因为没窗口就没组）
            .onDrop(of: [.text], isTargeted: nil) { providers in
                if let draggedWindow = DragDropManager.shared.draggingWindow, let targetWindow = windows.first, draggedWindow !== targetWindow {
                    moveTab(from: draggedWindow, toGroupOf: targetWindow)
                    DragDropManager.shared.draggingWindow = nil
                    return true
                }
                return false
            }
        }
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
    
    private func moveTab(from draggedWindow: NSWindow, toGroupOf targetWindow: NSWindow) {
        DispatchQueue.main.async {
            if let tabs = targetWindow.tabbedWindows, tabs.contains(draggedWindow) { return }
            targetWindow.addTabbedWindow(draggedWindow, ordered: .above)
            WindowRegistry.shared.objectWillChange.send()
        }
    }
}

struct TabItemView: View {
    let window: NSWindow
    @State private var isHovering = false
    
    var body: some View {
        HStack {
            Image(systemName: "doc.text")
                .foregroundColor(.gray)
            Text(window.title.isEmpty ? "未命名文档" : window.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(isHovering ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            // 激活此标签页对应的窗口
            window.makeKeyAndOrderFront(nil)
        }
        // 拖拽源
        .onDrag {
            // 传递一个标识符来唯一确定被拖拽的 window
            let provider = NSItemProvider(object: window.title as NSString)
            DragDropManager.shared.draggingWindow = window
            return provider
        }
        // 放置目标 (在某个现有的 Tab 上放开)
        .onDrop(of: [.text], isTargeted: nil) { providers in
            if let draggedWindow = DragDropManager.shared.draggingWindow, draggedWindow !== window {
                // 执行跨窗口 Tab 移动
                moveTab(from: draggedWindow, toGroupOf: window)
                DragDropManager.shared.draggingWindow = nil
                return true
            }
            return false
        }
    }
    
    private func moveTab(from draggedWindow: NSWindow, toGroupOf targetWindow: NSWindow) {
        DispatchQueue.main.async {
            if let tabs = targetWindow.tabbedWindows, tabs.contains(draggedWindow) { return }
            targetWindow.addTabbedWindow(draggedWindow, ordered: .above)
            WindowRegistry.shared.objectWillChange.send()
        }
    }
}

struct EmptyGroup: Identifiable {
    let id = UUID()
    var name: String = "未命名分组"
}

struct EmptyGroupSection: View {
    var emptyGroup: EmptyGroup
    var groupIndex: Int
    var onUpdate: (EmptyGroup) -> Void
    var onRemove: () -> Void
    
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editingName = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isEditing {
                    TextField("", text: $editingName, onCommit: {
                        finishEditing()
                    })
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onAppear {
                        editingName = emptyGroup.name
                        isFocused = true
                    }
                } else {
                    Text(displayTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .onTapGesture(count: 2) {
                            startEditing()
                        }
                    
                    if isHovering {
                        Button(action: { startEditing() }) {
                            Image(systemName: "pencil")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .onHover { hovering in
                isHovering = hovering
            }
            
            // "+" Button to open file
            Button(action: {
                openFileInNewWindow()
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "plus")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .onDrop(of: [.text], isTargeted: nil) { providers in
                if let draggedWindow = DragDropManager.shared.draggingWindow {
                    draggedWindow.moveTabToNewWindow(nil)
                    if emptyGroup.name != "未命名分组" {
                        let key = "CustomGroupName_\(draggedWindow.windowNumber)"
                        UserDefaults.standard.set(emptyGroup.name, forKey: key)
                    }
                    
                    DragDropManager.shared.draggingWindow = nil
                    WindowRegistry.shared.objectWillChange.send()
                    onRemove()
                    return true
                }
                return false
            }
        }
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
    
    private var displayTitle: String {
        emptyGroup.name == "未命名分组" ? "未命名分组 \(groupIndex)" : emptyGroup.name
    }
    
    private func startEditing() {
        editingName = emptyGroup.name
        isEditing = true
    }
    
    private func finishEditing() {
        isEditing = false
        if !editingName.trimmingCharacters(in: .whitespaces).isEmpty {
            var updated = emptyGroup
            updated.name = editingName
            onUpdate(updated)
        }
    }
    
    private func openFileInNewWindow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            let window = NSApp.openSwiftUIWindow(for: url, independent: true)
            if emptyGroup.name != "未命名分组" {
                let key = "CustomGroupName_\(window.windowNumber)"
                UserDefaults.standard.set(emptyGroup.name, forKey: key)
            }
            
            onRemove()
        }
    }
}

// 简单的单例用来暂存拖拽过程中的引用
class DragDropManager {
    static let shared = DragDropManager()
    var draggingWindow: NSWindow?
}
#endif
