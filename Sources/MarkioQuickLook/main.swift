import Foundation

// Never executed. The binary's entry point is Foundation's `_NSExtensionMain`,
// set with `-e` in Package.swift — the same thing Xcode does when it links an
// app-extension product. SwiftPM only requires an executable target to define
// an entry symbol, and this stub is it.
fatalError("MarkioQuickLook is an app extension; it starts via NSExtensionMain, never main()")
