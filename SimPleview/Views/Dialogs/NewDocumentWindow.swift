import SwiftUI

#if os(macOS)
import AppKit

struct NewDocumentWindow: View {
    @State private var selectedType: DocumentGenerator.DocumentType = .pdf
    
    typealias PaperSize = FilePreferences.Paper
    @State private var selectedPaperSize: PaperSize
    @State private var customWidth: String
    @State private var customHeight: String

    @AppStorage("appLanguage") private var appLangStr: String = "zh"
    private var lang: AppLanguage {
        AppLanguage(rawValue: appLangStr) ?? .zh
    }
    
    @State private var fileName: String = ""
    @State private var isCreating = false
    @State private var saveDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    
    var onClose: () -> Void
    
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let defaults = UserDefaults.standard
        _selectedType = State(initialValue: defaults.string(forKey: "newFileType").flatMap(DocumentGenerator.DocumentType.init(rawValue:)) ?? .pdf)
        _selectedPaperSize = State(initialValue: defaults.string(forKey: "newFilePaper").flatMap(PaperSize.init(rawValue:)) ?? .custom)
        let size = FilePreferences.newSize()
        _customWidth = State(initialValue: String(format: "%.2f", size.width))
        _customHeight = State(initialValue: String(format: "%.2f", size.height))
    }
    
    private func updateDimensions(for size: PaperSize) {
        if let dim = size.size {
            customWidth = String(format: "%.2f", dim.width)
            customHeight = String(format: "%.2f", dim.height)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Main content area
            VStack(spacing: 24) {
                
                // Document Properties Section
                VStack(alignment: .leading, spacing: 12) {
                    Text(SimPleview.L.s("Document Properties", lang))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 16) {
                        GridRow {
                            Text(SimPleview.L.s("File Type:", lang))
                                .gridColumnAlignment(.trailing)
                            Picker("", selection: $selectedType) {
                                ForEach(DocumentGenerator.DocumentType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 150)
                        }
                        
                        GridRow {
                            Text(SimPleview.L.s("Paper Size:", lang))
                                .gridColumnAlignment(.trailing)
                            Picker("", selection: $selectedPaperSize) {
                                ForEach(PaperSize.allCases) { size in
                                    Text(SimPleview.L.s(size.rawValue, lang)).tag(size)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 150)
                            .onChange(of: selectedPaperSize) { _, newValue in
                                updateDimensions(for: newValue)
                            }
                        }
                        
                        GridRow {
                            Text("") // Empty label
                            HStack(spacing: 8) {
                                TextField(SimPleview.L.s("Width", lang), text: $customWidth)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(selectedPaperSize != .custom)
                                    .frame(width: 65)
                                
                                Text("x")
                                    .foregroundColor(.secondary)
                                
                                TextField(SimPleview.L.s("Height", lang), text: $customHeight)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(selectedPaperSize != .custom)
                                    .frame(width: 65)
                                
                                Text("pt").foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.leading, 8)
                }
                
                // Save Options Section
                VStack(alignment: .leading, spacing: 12) {
                    Text(SimPleview.L.s("Save Options", lang))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 16) {
                        GridRow {
                            Text(SimPleview.L.s("File Name:", lang))
                                .gridColumnAlignment(.trailing)
                            TextField(SimPleview.L.s("Untitled", lang), text: $fileName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        }
                        
                        GridRow {
                            Text(SimPleview.L.s("Save To:", lang))
                                .gridColumnAlignment(.trailing)
                            HStack {
                                Text(saveDirectory.path)
                                    .truncationMode(.middle)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                
                                Button(SimPleview.L.s("Browse...", lang)) {
                                    selectDirectory()
                                }
                            }
                        }
                    }
                    .padding(.leading, 8)
                }
                
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            
            // Bottom Action Bar
            HStack {
                Spacer()
                Button(SimPleview.L.s("Cancel", lang)) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                
                Button(SimPleview.L.s("Create", lang)) {
                    createDocument()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(
                Divider(), alignment: .top
            )
        }
        .frame(width: 480, height: 420)
        .onAppear {
            if fileName.isEmpty {
                fileName = SimPleview.L.s("Untitled", lang)
            }
        }
    }
    
    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url
        }
    }
    
    private func createDocument() {
        guard !isCreating, NSApp.modalWindow == nil else { return }
        isCreating = true
        defer { isCreating = false }
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            let alert = NSAlert()
            alert.messageText = L.s("Invalid File Name", lang)
            alert.runModal()
            return
        }
        guard let w = Double(customWidth), let h = Double(customHeight),
              FilePreferences.validSize(CGSize(width: w, height: h)) else {
            let alert = NSAlert()
            alert.messageText = SimPleview.L.s("Invalid Page Size", lang)
            alert.runModal()
            return
        }
        let targetURL = saveDirectory.appendingPathComponent("\(name).\(selectedType.ext)")
        // 直接写指定目录不会获得 NSSavePanel 的覆盖保护，必须在已有文件时明确确认。
        if FileManager.default.fileExists(atPath: targetURL.path) {
            let alert = NSAlert()
            alert.messageText = L.format("Replace Existing File?", lang, targetURL.lastPathComponent)
            alert.addButton(withTitle: L.s("Cancel", lang))
            alert.addButton(withTitle: L.s("Replace", lang))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        
        do {
            try DocumentGenerator.generateBlankDocument(
                type: selectedType,
                width: w,
                height: h,
                targetURL: targetURL,
                backgroundColor: .white
            )
            
            // 自动打开生成的文件
            NSApp.openSwiftUIWindow(for: targetURL)
            
            // 使用回调安全关闭弹窗，避免操作丢失的引用
            onClose()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
#endif
