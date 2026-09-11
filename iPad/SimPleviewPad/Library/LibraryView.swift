import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @StateObject private var library = NotebookLibrary()
    @State private var chooseFolder = false
    var body: some View {
        NavigationStack {
            LibraryFolderView(library: library, directory: library.root)
                .id(library.root)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("选择笔记目录", systemImage: "folder.badge.gearshape") { chooseFolder = true }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink("恢复的笔记") {
                            LibraryFolderView(library:library,directory:URL.documentsDirectory.appendingPathComponent("恢复的笔记",isDirectory:true))
                        }
                    }
                }
        }
        .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): library.selectRoot(url)
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("好") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
}

struct LibraryFolderView: View {
    @ObservedObject var library: NotebookLibrary
    let directory: URL
    @State private var entries: [LibraryEntry] = []
    @StateObject private var fileOpening = OriginalFileOpening()
    @State private var create = false
    @State private var folder = false
    @State private var name = ""
    @State private var paper = NotebookPaper.ruled
    @State private var importing = false
    @State private var renaming: LibraryEntry?
    @State private var moving: LibraryEntry?
    @State private var deleting: LibraryEntry?
    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("还没有笔记", systemImage: "book.closed", description: Text("创建笔记本、打开原 PDF，或导入 PDF 副本。"))
            }
            ForEach(entries) { entry in
                Group {
                    if entry.folder {
                        NavigationLink {
                            LibraryFolderView(library: library, directory: entry.url)
                        } label: { Label(entry.title, systemImage: "folder") }
                    } else {
                        Button { fileOpening.opened = entry } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "book.closed.fill").font(.title).foregroundStyle(.tint)
                                Text(entry.title).foregroundStyle(.primary).padding(.vertical, 12)
                            }
                        }
                    }
                }
                .contextMenu {
                    Button("重命名", systemImage: "pencil") { name = entry.title; renaming = entry }
                    Button("移动", systemImage: "folder") { moving = entry }
                    Button("删除", systemImage: "trash", role: .destructive) { deleting = entry }
                }
            }
        }
        .navigationTitle(directory.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("打开文件", systemImage: "doc") { fileOpening.begin() }
                    .help("直接编辑所选 PDF，修改保存到原文件。")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建笔记本", systemImage: "book.badge.plus") { name = ""; folder = false; create = true }
                    Button("新建文件夹", systemImage: "folder.badge.plus") { name = ""; folder = true; create = true }
                    Button("导入 PDF 副本", systemImage: "square.and.arrow.down") { importing = true }
                    Button("刷新", systemImage: "arrow.clockwise") { refresh() }
                } label: { Label("添加", systemImage: "plus") }
            }
        }
        .task(id: library.revision) { refresh() }
        .refreshable { refresh() }
        .sheet(isPresented: $create) {
            NavigationStack {
                Form {
                    TextField(folder ? "文件夹名称" : "笔记本名称", text: $name)
                    if !folder { Picker("纸张", selection: $paper) { ForEach(NotebookPaper.allCases) { Text($0.rawValue).tag($0) } } }
                }
                .navigationTitle(folder ? "新建文件夹" : "新建笔记本")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { create = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") {
                            do {
                                _ = try library.create(name: name, paper: paper, folder: folder, in: directory)
                                create = false
                            } catch { library.error = error.localizedDescription; create = false }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.presentationDetents([.medium])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            do { for url in try result.get() { try library.importPDF(url, into: directory) } }
            catch { library.error = error.localizedDescription }
            refresh()
        }
        .sheet(isPresented: $fileOpening.pickerPresented, onDismiss: fileOpening.didDismiss) {
            OriginalPDFPicker { fileOpening.didSelect($0) }
        }
        .fullScreenCover(item: $fileOpening.opened, onDismiss: { refresh() }) { entry in
            NotebookReaderView(url: entry.url)
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let renaming { perform { try library.rename(renaming, to: name) } }
                renaming = nil
            }
        }
        .alert("删除后无法撤销", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let deleting { perform { try library.remove(deleting) } }; deleting = nil
            }
        } message: { Text(deleting?.title ?? "") }
        .sheet(item: $moving) { entry in
            NavigationStack {
                FolderDestinationView(library: library, directory: library.root) { target in
                    perform { try library.move(entry, into: target) }; moving = nil
                }
            }
        }
    }
    private func refresh() {
        do { entries = try library.entries(in: directory) } catch { library.error = error.localizedDescription }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { library.error = error.localizedDescription }
    }
}

/// 选择和关闭回调共用同一个引用状态，避免首次呈现时捕获旧的选择值。
/// 只有收到原 URL 且选择器已退场才打开阅读器；两种回调顺序都只打开一次。
@MainActor final class OriginalFileOpening: ObservableObject {
    @Published var pickerPresented = false
    @Published var opened: LibraryEntry?
    private var selectedURL: URL?
    private var dismissed = false

    func begin() {
        selectedURL = nil
        dismissed = false
        pickerPresented = true
    }
    func didSelect(_ url: URL?) {
        selectedURL = url
        pickerPresented = false
        openIfReady()
    }
    func didDismiss() {
        dismissed = true
        openIfReady()
    }
    private func openIfReady() {
        guard dismissed, let url = selectedURL else { return }
        selectedURL = nil
        opened = LibraryEntry(url: url, folder: false)
    }
}

/// 明确要求系统返回原文件的授权 URL，而不是导入到应用的临时副本。
/// URL 原样交给 NotebookSession；访问权限在阅读期间持有，保存仍写回该 URL。
struct OriginalPDFPicker: UIViewControllerRepresentable {
    let onSelection: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelection) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelection: (URL?) -> Void
        init(_ onSelection: @escaping (URL?) -> Void) { self.onSelection = onSelection }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onSelection(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onSelection(nil) }
    }
}

struct FolderDestinationView: View {
    @ObservedObject var library: NotebookLibrary
    let directory: URL
    let select: (URL) -> Void
    @State private var folders: [LibraryEntry] = []
    var body: some View {
        List(folders) { folder in
            NavigationLink(folder.title) { FolderDestinationView(library: library, directory: folder.url, select: select) }
        }
        .navigationTitle(directory.lastPathComponent)
        .toolbar { Button("移入此文件夹") { select(directory) } }
        .task {
            do { folders = try library.entries(in: directory).filter(\.folder) }
            catch { library.error = error.localizedDescription }
        }
    }
}
