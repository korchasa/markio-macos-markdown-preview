// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Markio2",
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
            name: "Markio2",
            dependencies: ["MarkdownKit", "MarkioRender"],
            path: "Sources/Markio2",
            exclude: ["AGENTS.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Headless performance harness: parse/layout timings and peak memory on
        // generated documents. Kept out of the app so its cost never ships.
        .executableTarget(
            name: "markio2-bench",
            dependencies: ["MarkdownKit", "MarkioRender"],
            path: "Sources/markio2-bench",
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
    ]
)
