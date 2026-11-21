import AppKit
import PDFKit

extension AppState {
    var canFillForms: Bool {
        guard let document = pdfView.document else { return false }
        return !document.isLocked && document.allowsFormFieldEntry
    }

    func toggleFormFilling() {
        guard canFillForms else { return }
        pdfView.coalesceRenderSnapshots {
            guard pdfView.formSession.commit() else { return }
            pdfView.finishTextBoxPlacement()
            if !isFormFilling {
                pdfView.commitDraftInk()
                if activeType != .none { activeType = .none }
                pdfView.activeType = .none
                if !areAnnotationsVisible { areAnnotationsVisible = true }
                if selectedAnnotation != nil { selectedAnnotation = nil }
                pdfView.currentSelectedBatchID = nil
                if pdfView.currentSelection != nil { pdfView.clearSelection() }
            }
            isFormFilling.toggle()
            pdfView.window?.makeFirstResponder(pdfView)
        }
    }
}
