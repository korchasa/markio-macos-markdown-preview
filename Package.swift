// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Markio",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Markio",
            path: "Sources/Markio",
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
        .testTarget(
            name: "MarkioTests",
            dependencies: ["Markio"],
            path: "Tests/MarkioTests"
        )
    ]
)
