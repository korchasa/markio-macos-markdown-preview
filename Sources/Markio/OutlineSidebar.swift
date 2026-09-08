import AppKit
import MarkdownKit
import MarkioRender

/// The heading tree, as a plain list with indentation, with the document's
/// boxes listed under the headings they sit beneath.
///
/// A table rather than an outline view: the headings are already in reading
/// order and collapsing them would hide the thing the sidebar exists to show.
/// Rows are created on demand by the table, so a document with ten thousand
/// headings costs the same as one with ten.
///
/// The headings are known the moment the document is parsed; the boxes arrive
/// from the background count, in batches. The rows are merged again as batches
/// come in, but at most a few times a second: a 32 MB document reports a
/// thousand batches over its walk, and rebuilding a six-figure row list on the
/// main thread for each of them is the cost the invariant forbids.
@MainActor
final class OutlineSidebar: NSView {
    var onSelectHeading: ((Int) -> Void)?
    /// Called with the ordinal of the box the reader clicked.
    var onSelectTask: ((Int) -> Void)?

    /// One row of the table: a heading, by its index, or a box.
    enum Row: Equatable {
        case heading(Int)
        case task(DocumentSummary.TaskEntry)
    }

    /// The least time between two merges of the rows while batches keep
    /// arriving. The count itself flushes every 500 leaves.
    static let rebuildInterval: TimeInterval = 0.25

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var headings: [Document.Heading] = []
    private var tasks: [DocumentSummary.TaskEntry] = []
    private(set) var rows: [Row] = []
    /// The row of each heading, so the scroll can select its section whatever
    /// boxes sit between the headings.
    private(set) var headingRows: [Int] = []
    private var rebuild: DispatchWorkItem?
    /// Ticked-of-total per section, as the background count reports it. Empty
    /// until the first batch arrives, and shorter than `headings` while the
    /// count is still walking the document.
    private var progress: [DocumentSummary.SectionProgress] = []
    /// The heading whose section the reader is in, or −1.
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
        tasks = []
        rebuild?.cancel()
        rebuild = nil
        current = -1
        rows = headings.indices.map(Row.heading)
        headingRows = Array(headings.indices)
        tableView.reloadData()
    }

    /// The per-section counts, from the summary. Called repeatedly while the
    /// numbers settle, so it redraws the rows rather than rebuilding them.
    func setProgress(_ progress: [DocumentSummary.SectionProgress]) {
        guard progress != self.progress else { return }
        self.progress = progress
        let rows = IndexSet(integersIn: 0..<max(0, self.rows.count))
        guard !rows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    /// The boxes one batch of the count found, in document order. The rows are
    /// merged soon rather than now, and at once when the count is complete.
    func addTasks(_ entries: [DocumentSummary.TaskEntry], complete: Bool) {
        guard !entries.isEmpty || complete else { return }
        tasks.append(contentsOf: entries)
        if complete {
            rebuild?.cancel()
            rebuild = nil
            rebuildRows()
            return
        }
        guard rebuild == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuild = nil
            self.rebuildRows()
        }
        rebuild = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rebuildInterval, execute: item)
    }

    /// Headings in order, each followed by the boxes of its section. A box
    /// before the first heading comes first. One pass: the boxes arrive in
    /// document order, so their sections never go backwards.
    private func rebuildRows() {
        var merged: [Row] = []
        merged.reserveCapacity(headings.count + tasks.count)
        var headingRows: [Int] = []
        headingRows.reserveCapacity(headings.count)
        var next = 0
        for index in headings.indices {
            while next < tasks.count, tasks[next].section < index {
                merged.append(.task(tasks[next]))
                next += 1
            }
            headingRows.append(merged.count)
            merged.append(.heading(index))
        }
        while next < tasks.count {
            merged.append(.task(tasks[next]))
            next += 1
        }
        rows = merged
        self.headingRows = headingRows
        tableView.reloadData()
        // A reload drops the selection, and the reader has not moved.
        select(heading: current)
    }

    /// Highlight the section the reader is in, following the scroll rather than
    /// a click.
    func setCurrent(_ index: Int) {
        guard index != current else { return }
        current = index
        select(heading: index)
    }

    private func select(heading index: Int) {
        suppressSelectionCallback = true
        if index >= 0, index < headingRows.count {
            let row = headingRows[index]
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        suppressSelectionCallback = false
    }

    /// What a box's row says: its first line, struck through once it is ticked.
    static func taskTitle(_ entry: DocumentSummary.TaskEntry) -> NSAttributedString {
        // The ellipsis has to live in the text itself: an attributed value
        // brings its own paragraph style, and the field's line-break mode is
        // ignored the moment one is set.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: entry.isChecked
                ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        if entry.isChecked {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.tertiaryLabelColor
        }
        return NSAttributedString(string: entry.title, attributes: attributes)
    }
}

extension OutlineSidebar {
    /// A row's text, for a test to read the order by.
    func label(of row: Row) -> String {
        switch row {
        case .heading(let index): return headings[index].text
        case .task(let entry): return entry.title
        }
    }
}

extension OutlineSidebar: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        switch rows[row] {
        case .heading(let index):
            let identifier = NSUserInterfaceItemIdentifier("headingCell")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: self) as? HeadingCell
                ?? HeadingCell(identifier: identifier)
            cell.configure(
                headings[index], progress: index < progress.count ? progress[index] : nil)
            return cell
        case .task(let entry):
            let identifier = NSUserInterfaceItemIdentifier("taskCell")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: self) as? TaskCell
                ?? TaskCell(identifier: identifier)
            // One step in from its heading; a box before any heading sits
            // where a top-level heading's boxes would.
            let level = entry.section >= 0 ? headings[entry.section].level : 1
            cell.configure(entry, level: level)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .heading(let index):
            current = index
            onSelectHeading?(index)
        case .task(let entry):
            onSelectTask?(entry.ordinal)
        }
    }
}

/// A box's row: one line of its text, indented under its heading.
@MainActor
private final class TaskCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var indentConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        indentConstraint = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            indentConstraint,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code only") }

    func configure(_ entry: DocumentSummary.TaskEntry, level: Int) {
        label.attributedStringValue = OutlineSidebar.taskTitle(entry)
        indentConstraint.constant = 8 + CGFloat(max(0, level)) * 11
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
