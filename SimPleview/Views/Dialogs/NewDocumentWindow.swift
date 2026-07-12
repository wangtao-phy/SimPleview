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
    
    @State private var fileName: String = SimPleview.L.s("Untitled", UserDefaults.standard.string(forKey: "appLanguage") == "en" ? .en : .zh)
    
    @State private var saveDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    
    var onClose: () -> Void
    
    private func updateDimensions(for size: PaperSize) {
        if let dim = size.dimensions {
            customWidth = String(format: "%.0f", dim.width)
            customHeight = String(format: "%.0f", dim.height)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text("Document Properties").font(.headline)) {
                    Picker("File Type:", selection: $selectedType) {
                        ForEach(DocumentGenerator.DocumentType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    
                    Picker("Paper Size:", selection: $selectedPaperSize) {
                        ForEach(PaperSize.allCases) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .onChange(of: selectedPaperSize) { newValue in
                        updateDimensions(for: newValue)
                    }
                    
                    HStack {
                        TextField("Width", text: $customWidth)
                            .textFieldStyle(.roundedBorder)
                            .disabled(selectedPaperSize != .custom)
                            .frame(width: 80)
                        
                        Text("x")
                            .foregroundColor(.secondary)
                        
                        TextField("Height", text: $customHeight)
                            .textFieldStyle(.roundedBorder)
                            .disabled(selectedPaperSize != .custom)
                            .frame(width: 80)
                        
                        Text("px/pt").foregroundColor(.secondary)
                    }
                    .padding(.leading, 75) // 对齐标签
                }
                
                Divider().padding(.vertical, 8)
                
                Section(header: Text("Save Options").font(.headline)) {
                    TextField("File Name:", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                    
                    HStack {
                        Text("Save To:")
                        Text(saveDirectory.path)
                            .truncationMode(.middle)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 200, alignment: .leading)
                        Spacer()
                        Button("Browse...") {
                            selectDirectory()
                        }
                    }
                }
            }
            .padding(20)
            
            Divider()
            
            HStack {
                Spacer()
                Button("Cancel") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
                    createDocument()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 380)
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
