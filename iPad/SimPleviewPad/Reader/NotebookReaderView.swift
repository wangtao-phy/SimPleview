import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct PDFExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct NotebookReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: NotebookSession
    @State private var pages = false
    @State private var jumping = false
    @State private var pageNumber = ""
    @State private var addNote = false
    @State private var note = ""
    @State private var deletePage = false
    @State private var export: PDFExportFile?
    @State private var exporting = false
    @State private var preparing = false
    @State private var searching = false
    @State private var chat = false
    init(url: URL) { _session = StateObject(wrappedValue: NotebookSession(url: url)) }
    var body: some View {
        NavigationStack {
            Group {
                if session.document != nil { PadPDFView(session: session) }
                else if session.error == nil { ProgressView("正在打开 PDF…") }
                else { ContentUnavailableView("无法打开", systemImage: "doc.badge.ellipsis") }
            }
            .navigationTitle(session.url.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("书架", systemImage: "chevron.backward") {
                        Task { if await session.close() { dismiss() } }
                    }.disabled(session.isSaving)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("页面", systemImage: "square.grid.2x2") { pages = true }
                    Button("搜索", systemImage: "magnifyingglass") { searching = true }
                    Button("AI", systemImage: "bubble.left.and.text.bubble.right") { chat = true }
                    Menu {
                        Picker("新页纸张", selection: $session.paper) { ForEach(NotebookPaper.allCases) { Text($0.rawValue).tag($0) } }
                        Button("添加页面", systemImage: "doc.badge.plus") { session.insertPage() }
                        Button("复制当前页", systemImage: "plus.square.on.square") { session.duplicatePage() }
                        Button("删除当前页", systemImage: "trash", role: .destructive) { deletePage = true }.disabled((session.document?.pageCount ?? 0) < 2)
                        Divider()
                        Button("导出可编辑 PDF") { prepareExport(flattened: false) }
                        Button("导出通用矢量 PDF") { prepareExport(flattened: true) }
                        Toggle("允许手指书写", isOn: $session.fingerDrawing)
                    } label: { Label("更多", systemImage: "ellipsis.circle") }.disabled(preparing)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(session.writing ? "阅读" : "书写", systemImage: session.writing ? "hand.draw" : "pencil.tip") {
                        session.writing.toggle()
                        if session.writing { session.annotationsVisible = true }
                    }
                    Button("撤销", systemImage: "arrow.uturn.backward") { session.canvas?.undoManager?.undo() }
                    Button("重做", systemImage: "arrow.uturn.forward") { session.canvas?.undoManager?.redo() }
                    Menu {
                        Button("高亮选中文字") { session.markSelection(.highlight) }
                        Button("下划线") { session.markSelection(.underline) }
                        Button("删除线") { session.markSelection(.strikeOut) }
                        Button("添加文字笔记") { note = ""; addNote = true }
                    } label: { Label("标注", systemImage: "highlighter") }
                    Button("标注显隐", systemImage: session.annotationsVisible ? "eye" : "eye.slash") {
                        session.annotationsVisible.toggle()
                        if !session.annotationsVisible { session.writing = false }
                    }
                    Spacer()
                    Button("\(session.pageIndex+1) / \(session.document?.pageCount ?? 0)") {
                        pageNumber = String(session.pageIndex+1)
                        jumping = true
                    }
                    .monospacedDigit()
                    .disabled(session.document == nil)
                    .accessibilityLabel("跳转页面")
                    Button(session.isSaving ? "保存中…" : session.dirty ? "待保存" : "已保存") { Task { await session.save() } }
                        .disabled(session.isSaving).help("表示已写入文件，不代表云端已同步。")
                }
            }
        }
        .interactiveDismissDisabled()
        .task { await session.open() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await session.save() } } }
        .alert("操作未完成", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("好") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .alert("添加文字笔记", isPresented: $addNote) {
            TextField("笔记内容", text: $note)
            Button("取消", role: .cancel) {}
            Button("添加") { session.addNote(note) }
        }
        .alert("跳转页面", isPresented: $jumping) {
            TextField("页码", text: $pageNumber).keyboardType(.numberPad)
            Button("取消", role: .cancel) {}
            Button("跳转") {
                if let index = session.pageIndex(forPageNumber: pageNumber) { session.go(to: index) }
            }.disabled(session.pageIndex(forPageNumber: pageNumber) == nil)
        } message: { Text("请输入 1–\(session.document?.pageCount ?? 0) 之间的页码。") }
        .alert("删除当前页？", isPresented: $deletePage) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { session.removePage() }
        } message: { Text("本页内容和手写笔迹将一同删除。") }
        .sheet(isPresented: $pages) { PageListView(session: session) }
        .sheet(isPresented: $searching) { PDFSearchView(session: session) }
        .sheet(isPresented: $chat) { PadChatView(session: session) }
        .fileExporter(isPresented: $exporting, document: export, contentType: .pdf, defaultFilename: session.url.deletingPathExtension().lastPathComponent) { result in
            if case .failure(let error) = result { session.error = error.localizedDescription }
            export = nil
        }
    }
    private func prepareExport(flattened: Bool) {
        preparing = true
        Task {
            defer { preparing = false }
            do { export = PDFExportFile(data: try await session.storage.render(session.snapshot(), flattened: flattened)); exporting = true }
            catch { session.error = error.localizedDescription }
        }
    }
}

struct PageListView: View {
    @ObservedObject var session: NotebookSession
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: PadSaveSnapshot?
    @State private var contents = false
    var body: some View {
        NavigationStack {
            List {
                if contents {
                    ForEach(outlineRows(), id: \.index) { item in
                        Button { session.go(to: item.page); dismiss() } label: {
                            Text(item.title).padding(.leading, CGFloat(min(item.depth,8))*12)
                        }
                    }
                } else {
                ForEach(0..<(session.document?.pageCount ?? 0), id: \.self) { index in
                    Button { session.go(to: index); dismiss() } label: {
                        HStack {
                            if let snapshot {
                                PagePreview(snapshot: snapshot, storage: session.storage, index: index)
                                    .id("\(session.revision)-\(index)")
                            }
                        Label("第 \(index+1) 页", systemImage: index == session.pageIndex ? "doc.fill" : "doc")
                        }
                    }
                }.onMove { offsets, destination in
                    guard let from = offsets.first else { return }
                    session.movePage(from: from, to: destination > from ? destination-1 : destination)
                }
                }
            }.navigationTitle(contents ? "PDF 目录" : "页面排序").toolbar {
                Button(contents ? "页面" : "目录") { contents.toggle() }
                if !contents { EditButton() }
            }
            .task(id: session.revision) {
                do { snapshot = try session.snapshot() } catch { session.error = error.localizedDescription }
            }
        }
    }

    private func outlineRows() -> [(index: Int, title: String, page: Int, depth: Int)] {
        guard let document = session.document, let root = document.outlineRoot else { return [] }
        var rows: [(Int,String,Int,Int)] = [], stack = [(root,-1)], visited = Set<ObjectIdentifier>()
        while let (node,depth) = stack.popLast(), visited.count < 10_000 {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            if let page = (node.destination ?? (node.action as? PDFActionGoTo)?.destination)?.page {
                let index = document.index(for: page)
                if index != NSNotFound { rows.append((rows.count,node.label ?? "第 \(index+1) 页",index,max(0,depth))) }
            }
            for index in (0..<node.numberOfChildren).reversed() {
                if let child = node.child(at:index) { stack.append((child,depth+1)) }
            }
        }
        return rows
    }
}

private struct PagePreview: View {
    let snapshot: PadSaveSnapshot
    let storage: NotebookStorage
    let index: Int
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage:image).resizable().scaledToFit() }
            else { Image(systemName:"doc").foregroundStyle(.secondary) }
        }.frame(width:64,height:88)
        .task {
            // 仅为可见行生成小图，离开行时释放，不缓存整本书的高分辨率页面。
            guard let data = try? await storage.images(snapshot,pages:[index],maximumDimension:176).first?.jpeg,
                  !Task.isCancelled else { return }
            image = UIImage(data:data)
        }
    }
}

struct PDFSearchView: View {
    @ObservedObject var session: NotebookSession
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var results: [Int] = []
    @State private var busy = false
    var body: some View {
        NavigationStack {
            List(results, id: \.self) { index in
                Button("第 \(index+1) 页") { session.go(to: index); dismiss() }
            }
            .overlay { if busy { ProgressView() } }
            .navigationTitle("搜索 PDF 文字")
            .searchable(text: $text, prompt: "不包含未识别的手写文字")
            .task(id: text) {
                guard !text.isEmpty else { results = []; return }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    busy = true
                    let revision = session.revision
                    let found = try await session.storage.search(session.snapshot().background, text: text)
                    try Task.checkCancellation()
                    if revision == session.revision { results = found }
                } catch is CancellationError {} catch { session.error = error.localizedDescription }
                busy = false
            }
        }
    }
}
