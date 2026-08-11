// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Markio",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Pure-Swift Markdown engine: a byte-level GFM parser that never
        // allocates a String while scanning. No AppKit, no CoreText, no
        // Foundation-heavy types — this target is what the benchmarks measure.
        .target(
            name: "MarkdownKit",
            path: "Sources/MarkdownKit",
            exclude: ["AGENTS.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Layout and drawing: CoreText typesetting, a virtualized document
        // view, the theme, and the syntax highlighter. Depends on MarkdownKit
        // only — it never parses Markdown itself.
        .target(
            name: "MarkioRender",
            dependencies: ["MarkdownKit"],
            path: "Sources/MarkioRender",
            exclude: ["AGENTS.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // The macOS app shell: windows, menus, file handling, live reload.
        .executableTarget(
            name: "Markio",
            dependencies: ["MarkdownKit", "MarkioRender"],
            path: "Sources/Markio",
            exclude: ["AGENTS.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Quick Look preview extension: the same renderer, in Finder's preview
        // panel. Linked with `_NSExtensionMain` as its entry point, the way
        // Xcode links an app-extension product.
        .executableTarget(
            name: "MarkioQuickLook",
            dependencies: ["MarkdownKit", "MarkioRender"],
            path: "Sources/MarkioQuickLook",
            exclude: ["AGENTS.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("Quartz"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        // Headless performance harness: parse/layout timings and peak memory on
        // generated documents. Kept out of the app so its cost never ships.
        .executableTarget(
            name: "markio-bench",
            dependencies: ["MarkdownKit", "MarkioRender"],
            path: "Sources/markio-bench",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MarkdownKitTests",
            dependencies: ["MarkdownKit"],
            path: "Tests/MarkdownKitTests"
        ),
        .testTarget(
            name: "MarkioRenderTests",
            dependencies: ["MarkdownKit", "MarkioRender"],
            path: "Tests/MarkioRenderTests"
        ),
        // The app shell itself: the window and what a drag on it may do. The
        // window controller lives in the executable target, so the tests depend
        // on the executable rather than on a module carved out to be testable.
        .testTarget(
            name: "MarkioTests",
            dependencies: ["Markio"],
            path: "Tests/MarkioTests"
        ),
    ]
)
