import SwiftUI
import UniformTypeIdentifiers

/// One document window: the rendered preview plus the one on-screen reading
/// control — line width. Owns its own `DocumentModel` (no shared singleton).
/// [REF:sds:line-width] [REF:fr:line-width] [REF:fr:multidoc]
struct ContentView: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var model = DocumentModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openDocument) private var openDocument

    var body: some View {
        HStack(spacing: 0) {
            // Toggleable native TOC sidebar to the left of the preview.
            // [REF:fr:toc]
            if model.tocVisible {
                TOCSidebar(model: model)
                Divider()
            }
            PreviewView(webView: model.preview.webView)
                .frame(minWidth: 480, minHeight: 320)
                // The find HUD floats over the top-center of the content (it
                // does not push the document down). [REF:fr:find]
                .overlay(alignment: .top) {
                    if model.findPresented { findBar.padding(.top, 12) }
                }
        }
        // The width control lives in a bottom bar (not the toolbar), pinned
        // below the preview and spanning the whole window. [REF:fr:line-width]
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        // Route the app-level Find/TOC menus to this (focused) window's model.
        // [REF:fr:find] [REF:fr:toc]
        .focusedSceneValue(\.documentModel, model)
        // Show the document's full filesystem path in the title bar instead
        // of the bare file name (DocumentGroup's default). The proxy icon
        // (represented URL) is kept. [REF:fr:multidoc]
        .background(WindowTitleSetter(title: fileURL?.path ?? "Markio"))
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
        .task { await model.start(text: document.text, url: fileURL) }
        .onChange(of: colorScheme) { _, scheme in
            Task { await model.appearanceChanged(dark: scheme == .dark) }
        }
    }

    /// Dropping a file opens it in a NEW window rather than replacing this one.
    /// [REF:fr:multidoc]
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isMarkdown else { return }
            Task { @MainActor in
                do {
                    try await openDocument(at: url)
                } catch {
                    Log.app.error(
                        "drop open failed for \(url.path): \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    /// Floating compact find HUD: a solid pill (window-background fill, hairline
    /// border, drop shadow) centered at the top of the content — magnifier,
    /// query field, `current/total` counter, a separator, round prev/next
    /// arrows, and a filled close button. ↑/↓ and Enter/Shift+Enter move between
    /// matches; Esc/✕ closes. [REF:fr:find]
    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            FindTextField(
                text: Binding(
                    get: { model.findQuery },
                    set: {
                        model.findQuery = $0
                        model.runSearch()
                    }
                ),
                onNext: { model.findNext() },
                onPrevious: { model.findPrev() },
                onCancel: { closeFind() }
            )
            .frame(width: 150)

            Text("\(model.findResult.current)/\(model.findResult.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: 16)

            HUDButton(systemName: "chevron.up", iconSize: 10, diameter: 24) {
                model.findPrev()
            }
            .disabled(model.findResult.count == 0)

            HUDButton(systemName: "chevron.down", iconSize: 10, diameter: 24) {
                model.findNext()
            }
            .disabled(model.findResult.count == 0)

            HUDButton(systemName: "xmark", iconSize: 8, diameter: 20, filled: true) {
                closeFind()
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(
            Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        // Esc closes the HUD even when focus has left the field.
        .background {
            Button("", action: closeFind).keyboardShortcut(.cancelAction).hidden()
        }
    }

    private func closeFind() {
        model.closeFind()
    }

    /// Bottom bar holding the one persistent reading control: an absolute
    /// reading width in characters, stepped through presets (40…200 by 20).
    /// [REF:fr:line-width]
    private var bottomBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.left.and.right.text.vertical")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { model.contentWidth }, set: { model.setWidth($0) }),
                in: Double(ContentWidthStore.minWidth)...Double(ContentWidthStore.maxWidth),
                step: Double(ContentWidthStore.step)
            )
            .frame(width: 180)
            .controlSize(.small)
            .help("Reading width in characters")
            Text("\(Int(model.contentWidth)) ch")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Round icon button for the find HUD: a circular hit target that fills on
/// hover; the close variant carries a permanent fill. [REF:fr:find]
private struct HUDButton: View {
    let systemName: String
    let iconSize: CGFloat
    let diameter: CGFloat
    var filled = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 && isEnabled }
    }

    private var fill: Color {
        let base = Color(nsColor: .quaternaryLabelColor)
        if filled { return hovering ? base : base.opacity(0.6) }
        return hovering ? base.opacity(0.85) : .clear
    }
}
