// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Markio",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Shared rendering engine: the vendored web bundle (template.html +
        // vendor/) and its locator/inliner. Depended on by the app and the
        // Quick Look extension so the engine exists exactly once.
        .target(
            name: "MarkioEngine",
            path: "Sources/MarkioEngine",
            // Module doc, not a build input.
            exclude: ["AGENTS.md"],
            resources: [
                // Copied to the bundle root as siblings so template.html's
                // relative vendor/ URLs resolve offline.
                .copy("Resources/template.html"),
                .copy("Resources/vendor"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Markio",
            dependencies: ["MarkioEngine"],
            path: "Sources/Markio",
            // Module doc, not a build input.
            exclude: ["AGENTS.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Quick Look preview extension binary (.appex payload). App extensions
        // have no main entry point of their own: the linker entry is
        // Foundation's _NSExtensionMain, exactly as Xcode links
        // com.apple.product-type.app-extension products. The .appex bundle
        // around this binary is assembled by `make app`. [REF:fr:quicklook]
        .executableTarget(
            name: "MarkioQuickLook",
            dependencies: ["MarkioEngine"],
            path: "Sources/MarkioQuickLook",
            // Module doc, not a build input.
            exclude: ["AGENTS.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("Quartz"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        .testTarget(
            name: "MarkioTests",
            dependencies: ["Markio", "MarkioEngine"],
            path: "Tests/MarkioTests"
        ),
    ]
)
