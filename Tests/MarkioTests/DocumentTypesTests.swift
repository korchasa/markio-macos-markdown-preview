import AppKit
import XCTest

@testable import Markio

/// What the app tells the system it can open.
///
/// This is one string in a plist and one lookup in AppKit, and when they
/// disagree nothing crashes: the app opens documents from Finder exactly as
/// before, and only the Open… command goes quietly grey. So it is asserted
/// here rather than left to be noticed.
final class DocumentTypesTests: XCTestCase {
    private func packaged() throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MarkioTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package
        let plist = root.appendingPathComponent("packaging/Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return try XCTUnwrap(parsed?["CFBundleDocumentTypes"] as? [[String: Any]])
    }

    /// A Swift class is `Module.Class` to the Objective-C runtime, and a plist
    /// naming it without the module names nothing at all.
    func testTheDocumentClassInThePlistIsAClassThatExists() throws {
        let types = try packaged()
        XCTAssertFalse(types.isEmpty)
        for type in types {
            let name = try XCTUnwrap(type["NSDocumentClass"] as? String)
            XCTAssertTrue(name.contains("."), "\(name) has no module and resolves to nothing")
            XCTAssertTrue(
                NSClassFromString(name) is MarkdownDocument.Type,
                "\(name) is not the document class")
        }
    }

    /// And whatever the controller names, the runtime must be able to find it.
    ///
    /// It names nothing now — the plist is the one place — but a name that
    /// looks up to nothing is the exact shape of the bug, so this asks for the
    /// property rather than for its absence.
    func testTheControllerNamesNoClassTheRuntimeCannotFind() {
        let controller = MarkdownDocumentController()
        for name in controller.documentClassNames {
            XCTAssertNotNil(NSClassFromString(name), "\(name) resolves to nothing")
        }
        // Whatever type it is asked about, it answers with the one document
        // class it has — that part is still the app's own.
        XCTAssertTrue(
            controller.documentClass(forType: "public.plain-text") is MarkdownDocument.Type)
    }
}
