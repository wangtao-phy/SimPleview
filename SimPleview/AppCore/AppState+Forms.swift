import AppKit
import PDFKit

extension AppState {
    var canFillForms: Bool {
        guard let document = pdfView.document else { return false }
        return !document.isLocked && document.allowsFormFieldEntry
    }

    func toggleFormFilling() {
        guard canFillForms, pdfView.formSession.commit() else { return }
        if !isFormFilling {
            pdfView.commitDraftInk()
            activeType = .none
            pdfView.activeType = .none
            areAnnotationsVisible = true
            selectedAnnotation = nil
            pdfView.currentSelectedBatchID = nil
            pdfView.clearSelection()
        }
        isFormFilling.toggle()
        pdfView.window?.makeFirstResponder(pdfView)
    }
}
