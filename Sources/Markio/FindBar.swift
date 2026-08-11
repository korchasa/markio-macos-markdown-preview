import AppKit

/// The find surface: a floating capsule over the top-right of the text.
///
/// It floats rather than pushing the document down, so opening it does not move
/// the line the reader was on.
@MainActor
final class FindBar: NSVisualEffectView {
    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let counter = NSTextField(labelWithString: "")

    var query: String { field.stringValue }

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        field.placeholderString = "Find"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12)
        field.target = self
        field.action = #selector(fieldChanged)
        field.delegate = self

        counter.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        counter.textColor = .secondaryLabelColor

        let previous = button(symbol: "chevron.up", action: #selector(previousTapped))
        let next = button(symbol: "chevron.down", action: #selector(nextTapped))
        let close = button(symbol: "xmark", action: #selector(closeTapped))

        let stack = NSStackView(views: [field, counter, previous, next, close])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            field.widthAnchor.constraint(equalToConstant: 180),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code only") }

    private func button(symbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        onQueryChange?(field.stringValue)
    }

    func setCounter(current: Int, total: Int) {
        counter.stringValue = total == 0 ? "" : "\(current) of \(total)"
    }

    @objc private func fieldChanged() { onQueryChange?(field.stringValue) }
    @objc private func nextTapped() { onNext?() }
    @objc private func previousTapped() { onPrevious?() }
    @objc private func closeTapped() { onClose?() }
}

extension FindBar: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(field.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.shift) { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
