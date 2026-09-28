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
    @State private var deletePage = false
    @State private var export: PDFExportFile?
    @State private var exporting = false
    @State private var preparing = false
    @State private var searching = false
    @State private var chat = false
    var onOpened: (() -> Void)?
    init(url: URL, onOpened: (() -> Void)? = nil) {
        _session = StateObject(wrappedValue: NotebookSession(url: url))
        self.onOpened = onOpened
    }
    var body: some View {
        Group {
            if let renderer = session.softwareRenderer, session.document != nil {
                SoftwarePDFView(session: session, renderer: renderer).ignoresSafeArea(.container)
            }
            else if session.document != nil { PadPDFView(session: session).ignoresSafeArea(.container) }
            else if session.openingFailure == nil { ProgressView("正在打开 PDF…") }
            else {
                ContentUnavailableView {
                    Label("暂时无法打开", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(session.openingFailure ?? "请重试或返回书架。")
                } actions: {
                    Button("重试") {
                        session.error = nil
                        Task { await session.open() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 仅正文延伸到屏幕边缘；悬浮控件保留安全区，不占用 PDF 的布局高度。
        // 不给正文添加点击手势，避免与 PencilKit、选字及文内链接争夺触摸。
        .overlay(alignment: .top) { navigationControls.padding(8) }
        .overlay(alignment: .leading) {
            if session.isReadOnly {
                Button("兼容阅读 · 只读") {
                    session.error = "系统原生图形服务暂不可用，已用兼容模式打开。可以滚动、双指缩放、跳页和搜索；手写与标注编辑暂不可用。原 PDF 及其矢量标注没有改动。"
                }
                .font(.caption).modifier(ReaderFloatingControls()).padding(8)
            } else { annotationControls.padding(8) }
        }
        .overlay(alignment: .bottomTrailing) { pageControls.padding(8) }
        .ignoresSafeArea(.keyboard)
        .interactiveDismissDisabled()
        .task { await session.open(); if session.document != nil { onOpened?() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await session.save() } } }
        .alert("操作未完成", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("好") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .sheet(item: $session.textRequest) { request in
            AnnotationTextEditor(request: request) { text in session.saveAnnotationText(text, for: request) }
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
    private var navigationControls: some View {
        HStack(alignment: .top) {
            Button("书架", systemImage: "chevron.backward") {
                Task { if await session.close() { dismiss() } }
            }
            .disabled(session.isSaving)
            .help(session.url.deletingPathExtension().lastPathComponent)
            .modifier(ReaderFloatingControls())
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                Button("页面", systemImage: "square.grid.2x2") { pages = true }
                Button("搜索", systemImage: "magnifyingglass") { searching = true }
                Button("AI", systemImage: "bubble.left.and.text.bubble.right") { chat = true }
                Menu {
                    Text(session.url.deletingPathExtension().lastPathComponent)
                    Picker("翻页效果", selection: $session.pageTurning) {
                        ForEach(PageTurning.allCases) { Text($0.title).tag($0) }
                    }.disabled(session.isUsingTool || session.isReadOnly)
                    Picker("新页纸张", selection: $session.paper) { ForEach(NotebookPaper.allCases) { Text($0.rawValue).tag($0) } }.disabled(session.isReadOnly)
                    Button("添加页面", systemImage: "doc.badge.plus") { session.insertPage() }.disabled(session.isReadOnly)
                    Button("复制当前页", systemImage: "plus.square.on.square") { session.duplicatePage() }.disabled(session.isReadOnly)
                    Button("删除当前页", systemImage: "trash", role: .destructive) { deletePage = true }.disabled(session.isReadOnly || (session.document?.pageCount ?? 0) < 2)
                    Divider()
                    Button {
                        Task { await session.save() }
                    } label: {
                        Label(session.isSaving ? "保存中…" : session.dirty ? "待保存" : "已保存",
                              systemImage: session.isSaving ? "arrow.trianglehead.2.clockwise" : session.dirty ? "square.and.arrow.down" : "checkmark.circle")
                    }
                    .disabled(session.isSaving)
                    .help("表示已写入文件，不代表云端已同步。")
                    Button("导出可编辑 PDF") { prepareExport(flattened: false) }
                    Button("导出通用矢量 PDF") { prepareExport(flattened: true) }
                    Toggle("允许手指书写", isOn: $session.fingerDrawing).disabled(session.isReadOnly)
                } label: { Label("更多", systemImage: "ellipsis.circle") }.disabled(preparing)
            }
            .modifier(ReaderFloatingControls())
        }
    }

    private var annotationControls: some View {
        VStack(spacing: 0) {
            Button(session.writing ? "阅读" : "书写", systemImage: session.writing ? "hand.draw" : "pencil.tip") {
                session.adjustingInk = false
                session.writing.toggle()
                if session.writing { session.annotationsVisible = true }
            }
            Button("撤销", systemImage: "arrow.uturn.backward") { session.undo() }
                .disabled(!session.canUndo || session.isUsingTool)
                .keyboardShortcut("z", modifiers: .command)
            Button("重做", systemImage: "arrow.uturn.forward") { session.redo() }
                .disabled(!session.canRedo || session.isUsingTool)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("标注显隐", systemImage: session.annotationsVisible ? "eye" : "eye.slash") {
                session.annotationsVisible.toggle()
                if !session.annotationsVisible { session.writing = false; session.adjustingInk = false }
            }
        }
        .modifier(ReaderFloatingControls())
    }

    private var pageControls: some View {
        HStack(spacing: 0) {
            Button("\(session.pageIndex+1) / \(session.document?.pageCount ?? 0)") {
                pageNumber = String(session.pageIndex+1)
                jumping = true
            }
            .monospacedDigit()
            .disabled(session.document == nil)
            .accessibilityLabel("跳转页面")

        }
        .modifier(ReaderFloatingControls())
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

/// 按钮保持至少 44 点触摸区域，背景只包围按钮组，组外触摸直接交给 PDF。
private struct ReaderFloatingControls: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .buttonStyle(ReaderFloatingButtonStyle())
            .fixedSize()
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }
}

private struct ReaderFloatingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
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
                if !contents && !session.isReadOnly { EditButton() }
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
