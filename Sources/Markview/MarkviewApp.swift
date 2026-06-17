import AppKit
import SwiftUI

/// App entry point. Native SwiftUI shell + an AppKit delegate for Finder opens.
/// [REF:sds:app-shell] [REF:fr:open]
@main
struct MarkviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.attach(model) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

/// Bridges AppKit file-open events (Finder "Open With", `open file.md`, Dock
/// drop) into the SwiftUI model. URLs arriving before the window exists are
/// queued and flushed once the model attaches.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            Task { @MainActor in urls.filter(\.isMarkdown).forEach(model.open) }
        } else {
            pendingURLs.append(contentsOf: urls.filter(\.isMarkdown))
        }
    }

    @MainActor
    func attach(_ model: AppModel) {
        self.model = model
        let queued = pendingURLs
        pendingURLs.removeAll()
        if let last = queued.last { model.open(last) }
    }
}
