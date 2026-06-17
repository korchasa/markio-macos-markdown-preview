import SwiftUI
import UniformTypeIdentifiers

/// The single preview screen: the rendered document plus the one on-screen
/// reading control — line width. [REF:sds:line-width] [REF:fr:line-width]
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PreviewView(webView: model.preview.webView)
            .frame(minWidth: 480, minHeight: 320)
            .navigationTitle(model.documentTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { widthControl }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { model.handleDrop($0) }
            .task { await model.bootstrap() }
            .onChange(of: colorScheme) { _, scheme in
                model.appearanceChanged(dark: scheme == .dark)
            }
    }

    /// Always-reachable line-width slider — the one persistent reading control.
    private var widthControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right.text.vertical")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { model.contentWidth }, set: { model.setWidth($0) }),
                in: Double(ContentWidthStore.minWidth)...Double(ContentWidthStore.maxWidth)
            )
            .frame(width: 160)
            .help("Adjust reading width")
        }
    }
}
