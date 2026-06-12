import SwiftUI
import AppKit
import PaperKit

struct MarkupToolbarRepresentable: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> MarkupToolbarViewController {
        let vc = MarkupToolbarViewController(supportedFeatureSet: .latest)
        return vc
    }
    
    func updateNSViewController(_ nsViewController: MarkupToolbarViewController, context: Context) {
        
    }
}
