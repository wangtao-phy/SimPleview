import SwiftUI
import AppKit
import PDFKit

struct FormToolsButton: View {
    @ObservedObject var state: AppState
    @State private var isShowingTools = false

    var body: some View {
        Button {
            isShowingTools.toggle()
        } label: {
            Label(state.L("Form and Text Tools"), systemImage: "rectangle.and.pencil.and.ellipsis")
                .foregroundStyle(state.isFormFilling || state.isPlacingTextBox ? Color.accentColor : .primary)
        }
        .help(state.L(state.isPlacingTextBox ? "Text Box Placement Help" : "Form and Text Tools"))
        .disabled(!state.canFillForms && !state.canInsertTextBox)
        .popover(isPresented: $isShowingTools, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    isShowingTools = false
                    state.toggleFormFilling()
                } label: {
                    HStack {
                        Label(state.L("Form Filling"), systemImage: "rectangle.and.pencil.and.ellipsis")
                        Spacer(minLength: 12)
                        if state.isFormFilling { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                }
                .accessibilityValue(state.L(state.isFormFilling ? "On" : "Off"))
                .help(state.L("Form Filling Help"))
                .disabled(!state.canFillForms)

                Button {
                    isShowingTools = false
                    state.toggleTextBoxPlacement()
                } label: {
                    Label(state.L(state.isPlacingTextBox ? "Cancel Text Box Placement" : "Insert Text Box"),
                          systemImage: "textformat")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(state.L("Text Box Placement Help"))
                .disabled(!state.canInsertTextBox)
                if state.isPlacingTextBox {
                    Text(state.L("Text Box Placement Help")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(12)
            .frame(width: 228)
        }
        .sheet(item: $state.textBoxTarget, onDismiss: {
            state.pdfView.textBoxOverlay?.refresh()
        }) { target in
            TextBoxEditor(state: state, target: target)
        }
    }
}

private struct TextBoxEditor: View {
    let state: AppState
    let target: PDFTextBoxTarget
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingText: Bool
    @State private var text = ""
    @State private var family = "Helvetica"
    @State private var size = 14.0
    @State private var bold = false
    @State private var italic = false
    @State private var color = Color.black
    @State private var doesNotFit = false

    private let families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    init(state: AppState, target: PDFTextBoxTarget) {
        self.state = state
        self.target = target
        if let box = target.annotation {
            let style = box.textBoxStyle
            let font = style?.font ?? box.font ?? .systemFont(ofSize: 14)
            let traits = NSFontManager.shared.traits(of: font)
            _text = State(initialValue: box.contents ?? "")
            _family = State(initialValue: font.familyName ?? "Helvetica")
            _size = State(initialValue: font.pointSize)
            _bold = State(initialValue: traits.contains(.boldFontMask))
            _italic = State(initialValue: traits.contains(.italicFontMask))
            _color = State(initialValue: Color(nsColor: style?.color ?? box.fontColor ?? .black))
        }
    }

    private var font: NSFont {
        let pointSize = size.isFinite ? min(144, max(6, size)) : 14
        let manager = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if let old = target.annotation?.textBoxStyle?.font, old.familyName == family, old.pointSize == pointSize,
           manager.traits(of: old).intersection([.boldFontMask, .italicFontMask]) == traits { return old }
        return manager.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: pointSize)
            ?? manager.font(withFamily: family, traits: [], weight: 5, size: pointSize)
            ?? .systemFont(ofSize: pointSize, weight: bold ? .bold : .regular)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.L(target.annotation == nil ? "Insert Text Box" : "Edit Text Box")).font(.headline)
            HStack(spacing: 12) {
                Picker(state.L("Text Box Font"), selection: $family) {
                    ForEach(families, id: \.self) { name in Text(name).tag(name) }
                }
                .labelsHidden()
                .accessibilityLabel(state.L("Text Box Font"))
                .frame(maxWidth: .infinity)
                TextField(state.L("Text Box Font Size"), value: $size, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 46)
                Text("pt").foregroundStyle(.secondary)
                Toggle(isOn: $bold) { Image(systemName: "bold") }
                    .toggleStyle(.button).help(state.L("Text Box Bold")).accessibilityLabel(state.L("Text Box Bold"))
                Toggle(isOn: $italic) { Image(systemName: "italic") }
                    .toggleStyle(.button).help(state.L("Text Box Italic")).accessibilityLabel(state.L("Text Box Italic"))
                ColorPicker(state.L("Color"), selection: $color, supportsOpacity: false).labelsHidden()
            }

            TextEditor(text: $text)
                .font(Font(font))
                .foregroundStyle(color)
                .environment(\.colorScheme, .light)
                .scrollContentBackground(.hidden)
                .padding(3)
                .frame(height: 140)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .accessibilityLabel(state.L("Text Box Text"))
                .focused($editingText)
            if doesNotFit { Text(state.L("Text Box Does Not Fit")).font(.caption).foregroundStyle(.red) }

            HStack {
                if let annotation = target.annotation {
                    Button(state.L("Delete Text Box"), role: .destructive) {
                        state.deleteAnnotation(annotation)
                        dismiss()
                    }
                }
                Spacer()
                Button(state.L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(state.L(target.annotation == nil ? "Insert Text Box" : "Save")) {
                    let textColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
                    if state.saveTextBox(text, font: font, color: textColor, at: target) { dismiss() }
                    else { doesNotFit = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 442)
        .task { editingText = true }
    }
}
