import PDFKit

/// 描述待反向执行的编辑动作。页面和标注对象仅由所属窗口的主执行器使用；
/// 关闭或更换文档时必须同时清理两个历史栈，释放旧文档的引用。
enum UndoAction: Equatable {
    case annotation(batchID: String, pageIndices: Set<Int>)                                // 关联值是批次 ID，并携带受影响的页码集合以实现 O(K) 撤销
    case deleteAnnotation(annotations: [PDFAnnotation], pageIndices: [Int]) // 携带被删掉的标注及它们所在的页码
    case deletePage(page: PDFPage, index: Int)                              // 携带被删掉的整页对象
    case deletePages(pages: [PDFPage], indices: [Int])                      // 携带多页删除的数据，用于支持重做插入操作
    case insertPages(count: Int, startIndex: Int)
    case removePages(indices: [Int]) // 恢复非连续页面后的逆操作，保留精确位置
    case reorderPages(originalIndices: [Int], insertedAt: Int)

    // [逻辑流程]
    // 当我们需要比较栈顶动作时，Swift 允许我们使用模式匹配 (Pattern Matching) 解包关联值并进行比较。
    static func == (lhs: UndoAction, rhs: UndoAction) -> Bool {
        switch (lhs, rhs) {
        case (.annotation(let id1, let p1), .annotation(let id2, let p2)): return id1 == id2 && p1 == p2
        case (.deleteAnnotation(let a1, _), .deleteAnnotation(let a2, _)): return a1 == a2
        case (.deletePage(_, let i1), .deletePage(_, let i2)): return i1 == i2
        case (.deletePages(_, let i1), .deletePages(_, let i2)): return i1 == i2
        case (.insertPages(let c1, let s1), .insertPages(let c2, let s2)): return c1 == c2 && s1 == s2
        case (.removePages(let i1), .removePages(let i2)): return i1 == i2
        case (.reorderPages(let o1, let i1), .reorderPages(let o2, let i2)): return o1 == o2 && i1 == i2
        default: return false
        }
    }
}
