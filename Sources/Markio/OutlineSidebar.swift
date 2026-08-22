import AppKit
import MarkdownKit
import MarkioRender

/// The heading tree, as a plain list with indentation.
///
/// A table rather than an outline view: the headings are already in reading
/// order and collapsing them would hide the thing the sidebar exists to show.
/// Rows are created on demand by the table, so a document with ten thousand
/// headings costs the same as one with ten.
@MainActor
final class OutlineSidebar: NSView {
    var onSelect: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var headings: [Document.Heading] = []
    /// Ticked-of-total per section, as the background count reports it. Empty
    /// until the first batch arrives, and shorter than `headings` while the
    /// count is still walking the document.
    private var progress: [DocumentSummary.SectionProgress] = []
    private var current = -1
    private var suppressSelectionCallback = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code only") }

    private func build() {
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.style = .inset
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setHeadings(_ headings: [Document.Heading]) {
        self.headings = headings
        progress = []
        current = -1
        tableView.reloadData()
    }

    /// The per-section counts, from the summary. Called repeatedly while the
    /// numbers settle, so it redraws the rows rather than rebuilding them.
    func setProgress(_ progress: [DocumentSummary.SectionProgress]) {
        guard progress != self.progress else { return }
        self.progress = progress
        let rows = IndexSet(integersIn: 0..<max(0, headings.count))
        guard !rows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    /// Highlight the section the reader is in, following the scroll rather than
    /// a click.
    func setCurrent(_ index: Int) {
        guard index != current else { return }
        current = index
        suppressSelectionCallback = true
        if index >= 0, index < headings.count {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
        suppressSelectionCallback = false
    }
}

extension OutlineSidebar: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("headingCell")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? HeadingCell
            ?? HeadingCell(identifier: identifier)
        cell.configure(headings[row], progress: row < progress.count ? progress[row] : nil)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        current = row
        onSelect?(row)
    }
}

/// A single outline row: the heading text, indented by its level.
@MainActor
private final class HeadingCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    /// Ticked-of-total for this section, so the unfinished part of a report can
    /// be found without scrolling to it.
    private let badge = NSTextField(labelWithString: "")
    private var indentConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: 11.5)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        badge.textColor = .secondaryLabelColor
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        addSubview(badge)
        indentConstraint = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            indentConstraint,
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code only") }

    func configure(_ heading: Document.Heading, progress: DocumentSummary.SectionProgress?) {
        label.stringValue = heading.text
        indentConstraint.constant = 8 + CGFloat(max(0, heading.level - 1)) * 11
        label.font = NSFont.systemFont(
            ofSize: 11.5,
            weight: heading.level <= 2 ? .semibold : .regular
        )
        label.textColor = heading.level <= 2 ? .labelColor : .secondaryLabelColor
        // A section with no checkboxes shows nothing rather than "0/0": the
        // badge is a fact about the section, not a slot that must be filled.
        guard let progress, progress.tasks > 0 else {
            badge.stringValue = ""
            return
        }
        badge.stringValue = "\(progress.done)/\(progress.tasks)"
        badge.textColor =
            progress.done == progress.tasks ? .tertiaryLabelColor : .secondaryLabelColor
    }
}
