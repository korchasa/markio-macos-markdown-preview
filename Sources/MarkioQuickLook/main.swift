import Foundation

// Never executed. The binary's entry point is Foundation's _NSExtensionMain
// (set via `-e` in Package.swift linkerSettings — how Xcode links
// app-extension products); pluginkit drives the extension life cycle from
// there. SwiftPM merely requires executable targets to define an entry
// symbol, which this stub provides. [REF:fr:quicklook]
fatalError("MarkioQuickLook is an app extension; it starts via NSExtensionMain, never main()")
