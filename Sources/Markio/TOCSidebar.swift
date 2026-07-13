import SwiftUI

/// Native table-of-contents sidebar: the document's heading tree, indented by
/// level, with the current section highlighted and kept visible. Clicking a
/// row jumps the preview to that heading. Fixed width — minimal chrome, no
/// resize handle in v1. [REF:fr:toc] [REF:sds:toc-sidebar]
struct TOCSidebar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        Group {
            if model.outline.isEmpty {
                Text("No headings")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.outline) { item in
                                row(item)
                            }
                        }
                        .padding(8)
                    }
                    // Keep the highlighted row visible while the reader
                    // scrolls the document.
                    .onChange(of: model.currentHeadingID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 220)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ item: TOCItem) -> some View {
        let isCurrent = item.id == model.currentHeadingID
        return Button {
            model.jumpToHeading(item.id)
        } label: {
            Text(item.text)
                .font(item.level == 1 ? .callout.weight(.medium) : .callout)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(2)
                .padding(.leading, CGFloat(item.level - 1) * 12)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isCurrent ? Color.accentColor.opacity(0.18) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(item.id)
    }
}
