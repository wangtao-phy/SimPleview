import SwiftUI
import PDFKit

/// [教程注释：PDF 目录树视图]
/// 这是一个递归渲染的树状结构（Tree View），用于展示 PDF 自带的书签大纲 (Table of Contents)。
struct FlatOutlineItem: Identifiable, Equatable {
    let id: ObjectIdentifier
    let outline: PDFOutline
    let level: Int
    let hasChildren: Bool
    
    static func == (lhs: FlatOutlineItem, rhs: FlatOutlineItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// [教程注释：PDF 目录树视图]
/// 这是一个拍平的虚拟化列表（Flattened Virtualized List），用于展示 PDF 大纲。
/// 彻底摒弃了旧版的递归视图结构，利用单层 LazyVStack 实现了极其严苛的 O(1) 内存复用，向顶级原生阅读器看齐。
struct OutlineView: View {
    @ObservedObject var state: AppState
    
    // 存储被用户主动“收起”的节点 ID（默认全部展开，符合大多数人的阅读直觉）
    @State private var collapsedNodes = Set<ObjectIdentifier>()
    
    // [极致计算量优化：瞬间拍平结构]
    // 每次渲染只提取"当前可视状态下"的线性大纲，扔给底层 LazyVStack。
    // 这把千万级的递归视图开销直接降维打击成了几十个扁平格子的循环！
    var visibleItems: [FlatOutlineItem] {
        var items: [FlatOutlineItem] = []
        guard let root = state.pdfView.document?.outlineRoot else { return [] }
        
        func traverse(_ node: PDFOutline, level: Int) {
            let id = ObjectIdentifier(node)
            let hasChildren = node.numberOfChildren > 0
            items.append(FlatOutlineItem(id: id, outline: node, level: level, hasChildren: hasChildren))
            
            // 如果节点没有被收起，继续遍历子节点
            if hasChildren && !collapsedNodes.contains(id) {
                for i in 0..<node.numberOfChildren {
                    if let child = node.child(at: i) {
                        traverse(child, level: level + 1)
                    }
                }
            }
        }
        
        for i in 0..<root.numberOfChildren {
            if let child = root.child(at: i) { traverse(child, level: 0) }
        }
        return items
    }
    
    var body: some View {
        let items = visibleItems
        if !items.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        OutlineNodeRow(
                            item: item,
                            selectedOutline: state.selectedOutline,
                            isCollapsed: collapsedNodes.contains(item.id),
                            onToggleCollapse: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if collapsedNodes.contains(item.id) {
                                        collapsedNodes.remove(item.id)
                                    } else {
                                        collapsedNodes.insert(item.id)
                                    }
                                }
                            },
                            onSelect: {
                                state.selectedOutline = item.outline
                                if let dest = item.outline.destination {
                                    state.pdfView.go(to: dest)
                                    // [P0修复] 安全解包 dest.page，防止损坏的 PDF 目录导致崩溃
                                    if let page = dest.page {
                                        state.goToPage(state.pdfView.document?.index(for: page) ?? state.currentPageIndex)
                                    }
                                }
                            }
                        )
                        .id(item.id)
                    }
                }
                .padding(.vertical, 8)
            }
        } else {
            // [空状态展示]
            VStack {
                Spacer()
                Text("无目录").foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// [教程注释：被拍平后的单一目录单元格]
/// 这个视图极其轻量，再也不存在令人绝望的递归地狱了！
struct OutlineNodeRow: View {
    let item: FlatOutlineItem
    let selectedOutline: PDFOutline?
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onSelect: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            // [层级缩进]
            if item.level > 0 {
                Spacer().frame(width: CGFloat(item.level) * (PlatformUtils.isiOS ? 12 : 5))
            }
            
            // [展开/收起的小箭头]
            if item.hasChildren {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    // 收起时向右 (0度)，展开时向下 (90度)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle()) // 扩大箭头的热区
                    .onTapGesture {
                        onToggleCollapse()
                    }
            } else {
                Spacer().frame(width: 12)
            }
            
            // [目录标题文本]
            Text(item.outline.label ?? "未命名章节")
                .lineLimit(1)
                .font(.system(size: PlatformUtils.isiOS ? 15 : 13))
            
            Spacer()
        }
        .padding(.vertical, PlatformUtils.isiOS ? 12 : 8)
        .padding(.horizontal, PlatformUtils.isiOS ? 8 : 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle()) // 让整行可点击
        // [选中状态高亮]
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedOutline == item.outline ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(selectedOutline == item.outline ? .white : .primary)
        // [点击整行跳转页面]
        .onTapGesture {
            onSelect()
        }
    }
}
