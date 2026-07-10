import AppKit
import SwiftUI

/// `NSTextField` that grabs first responder the moment it is attached to a
/// window. Doing it here (rather than from `updateNSView`) is reliable: the HUD
/// is rebuilt on every open, so a fresh field is created and focuses itself once
/// it enters the window — no dependency on a later SwiftUI update. [REF:fr:find]
final class FocusingTextField: NSTextField {
    private var didFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didFocus, window != nil else { return }
        didFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// Borderless inline text field for the find HUD — no bezel, no focus ring, so
/// it reads as plain text inside the pill (the magnifier lives beside it as a
/// separate glyph). Live edits flow back through `text`; ↓/Enter → next,
/// ↑/Shift+Enter → previous, Esc → close. Focuses itself the first time it
/// enters a window. [REF:fr:find]
struct FindTextField: NSViewRepresentable {
    @Binding var text: String
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Search"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindTextField
        init(_ parent: FindTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift { parent.onPrevious() } else { parent.onNext() }
                return true
            // Arrow keys move between matches while the field keeps focus, so
            // the caret never leaves the query. [REF:fr:find]
            case #selector(NSResponder.moveUp(_:)):
                parent.onPrevious()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onNext()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
