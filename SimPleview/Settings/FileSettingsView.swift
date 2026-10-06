import SwiftUI
import UniformTypeIdentifiers

/// 文件尺寸、打开方式及导出偏好集中在这里；原文件的常规保存保留可编辑标注。
struct FileSettingsView: View {
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @AppStorage("newFileType") private var fileType = "PDF"
    @AppStorage("newFilePaper") private var paper = "Custom"
    @AppStorage("newFileWidth") private var width = 1600.0
    @AppStorage("newFileHeight") private var height = 800.0
    @AppStorage("insertPagePaper") private var insertPaper = "Match"
    @AppStorage("imageExportScale") private var imageScale = 1.0
    @AppStorage("jpegExportQuality") private var quality = 0.8
    @AppStorage("flattenPDFExport") private var flatten = true
    @State private var selectedImageFormat = "All"
    private func LS(_ key: String) -> String { L.s(key, language) }

    var body: some View {
        Form {
            Section(LS("New File Defaults")) {
                Picker(LS("File Type:"), selection: $fileType) {
                    ForEach(DocumentGenerator.DocumentType.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker(LS("Paper Size:"), selection: $paper) {
                    ForEach(FilePreferences.Paper.allCases) { Text(LS($0.rawValue)).tag($0.rawValue) }
                }
                if paper == "Custom" {
                    HStack {
                        Text(LS("Dimensions")); Spacer()
                        TextField(LS("Width"), value: $width, format: .number).frame(width: 85)
                        Text("×")
                        TextField(LS("Height"), value: $height, format: .number).frame(width: 85)
                        Text(fileType == "PDF" ? "pt" : "px").foregroundStyle(.secondary)
                    }
                    .onSubmit {
                        let size = FilePreferences.newSize()
                        width = size.width; height = size.height
                    }
                }
                Picker(LS("Inserted Blank Pages"), selection: $insertPaper) {
                    Text(LS("Match Adjacent Page")).tag("Match")
                    Text(LS("Use New File Size")).tag("New")
                    ForEach(FilePreferences.Paper.allCases.filter { $0 != .custom }) { Text(LS($0.rawValue)).tag($0.rawValue) }
                }
                Text(LS("Page Size Help")).font(.caption).foregroundStyle(.secondary)
            }
            Section(LS("Export Defaults")) {
                Picker(LS("Image Export Size"), selection: $imageScale) {
                    Text("50%").tag(0.5); Text("100%").tag(1.0); Text("150%").tag(1.5); Text("200%").tag(2.0)
                }
                HStack {
                    Text(LS("JPEG Quality"))
                    Slider(value: Binding(get: { FilePreferences.jpegQuality() }, set: { quality = $0 }), in: 0.1...1, step: 0.05)
                        .accessibilityLabel(LS("JPEG Quality"))
                    Text(FilePreferences.jpegQuality(), format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 45)
                }
                Toggle(LS("Flatten PDF Export"), isOn: $flatten)
                Text(LS("Export Defaults Help")).font(.caption).foregroundStyle(.secondary)
            }
            Section(LS("Default File Applications")) {
                HStack {
                    Picker(LS("File Type:"), selection: $selectedImageFormat) {
                        Text(LS("All Supported Formats")).tag("All")
                        Text("PDF").tag("PDF"); Text("PNG").tag("PNG")
                        Text("JPEG").tag("JPEG"); Text("TIFF").tag("TIFF")
                    }
                    Button(LS("Set as Default Viewer")) { setAsDefaultApplication() }
                }
                Text(LS("Default File Applications Help")).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func setAsDefaultApplication() {
        let app = Bundle.main.bundleURL
        let types: [UTType]
        switch selectedImageFormat {
        case "PDF": types = [.pdf]
        case "PNG": types = [.png]
        case "JPEG": types = [.jpeg]
        case "TIFF": types = [.tiff]
        default: types = [.pdf, .png, .jpeg, .tiff]
        }
        Task { @MainActor in
            var errors: [String] = []
            for type in types {
                let error: Error? = await withCheckedContinuation { continuation in
                    NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { continuation.resume(returning: $0) }
                }
                if let error { errors.append("\(type.identifier): \(error.localizedDescription)") }
            }
            let alert = NSAlert()
            alert.messageText = LS(errors.isEmpty ? "Default Viewer Set" : "Default Viewer Partially Set")
            alert.informativeText = errors.isEmpty ? app.lastPathComponent : errors.joined(separator: "\n")
            alert.runModal()
        }
    }
}
