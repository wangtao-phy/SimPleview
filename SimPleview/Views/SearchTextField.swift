import SwiftUI

#if os(macOS)
import AppKit

/// 彻底干掉 macOS 下 SwiftUI TextField 聚焦时闪烁白底/白框的终极解决方案
struct SearchTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onCommit: () -> Void
    var isFocused: Binding<Bool>

    func makeNSView(context: Context) -> NSTextField {
        let textField = CustomNSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.textColor = .labelColor
        // 干掉所有可能产生的视觉副作用
        textField.wantsLayer = true
        textField.layer?.backgroundColor = NSColor.clear.cgColor
        textField.onFocusRequested = { [weak textField] in
            DispatchQueue.main.async {
                if let tf = textField, let window = tf.window {
                    window.makeFirstResponder(tf)
                }
            }
        }
        
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        
        // 焦点同步
        if let customTextField = nsView as? CustomNSTextField {
            customTextField.syncFocusState(isFocused: isFocused.wrappedValue)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class CustomNSTextField: NSTextField {
        var onFocusRequested: (() -> Void)?
        private var pendingFocusRequest = false
        
        func syncFocusState(isFocused: Bool) {
            if isFocused {
                if window?.firstResponder != self.currentEditor() {
                    if window != nil {
                        window?.makeFirstResponder(self)
                    } else {
                        pendingFocusRequest = true
                    }
                }
            } else {
                pendingFocusRequest = false
                if window?.firstResponder == self.currentEditor() {
                    window?.makeFirstResponder(nil)
                }
            }
        }
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil && pendingFocusRequest {
                pendingFocusRequest = false
                onFocusRequested?()
            }
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextField

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }
        
        func controlTextDidBeginEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused.wrappedValue = true
            }
        }
        
        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused.wrappedValue = false
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }
}
#endif
