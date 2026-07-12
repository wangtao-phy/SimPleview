import SwiftUI

#if os(macOS)
import AppKit

struct NewDocumentWindow: View {
    @State private var selectedType: DocumentGenerator.DocumentType = .pdf
    
    enum PaperSize: String, CaseIterable, Identifiable {
        case custom = "Custom"
        case a4 = "A4"
        case a3 = "A3"
        case b5 = "B5"
        case usLetter = "US Letter"
        
        var id: String { self.rawValue }
        
        var dimensions: CGSize? {
            switch self {
            case .a4: return CGSize(width: 595.28, height: 841.89) // at 72 PPI
            case .a3: return CGSize(width: 841.89, height: 1190.55)
            case .b5: return CGSize(width: 498.90, height: 708.66)
            case .usLetter: return CGSize(width: 612, height: 792)
            case .custom: return nil
            }
        }
    }
    
    @State private var selectedPaperSize: PaperSize = .custom
    @State private var customWidth: String = "1600"
    @State private var customHeight: String = "800"
    
    @AppStorage("appLanguage") private var appLangStr: String = "zh"
    private var lang: AppLanguage {
        AppLanguage(rawValue: appLangStr) ?? .zh
    }
    
    @State private var fileName: String = ""
    @State private var saveDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    
    var onClose: () -> Void
    
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }
    
    private func updateDimensions(for size: PaperSize) {
        if let dim = size.dimensions {
            customWidth = String(format: "%.0f", dim.width)
            customHeight = String(format: "%.0f", dim.height)
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
                                    Text(size.rawValue).tag(size)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 150)
                            .onChange(of: selectedPaperSize) { newValue in
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
        let w = CGFloat(Double(customWidth) ?? 1600)
        let h = CGFloat(Double(customHeight) ?? 800)
        
        let targetURL = saveDirectory.appendingPathComponent("\(fileName).\(selectedType.ext)")
        
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
