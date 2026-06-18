// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Markview",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Markview",
            path: "Sources/Markview",
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
            name: "MarkviewTests",
            dependencies: ["Markview"],
            path: "Tests/MarkviewTests"
        )
    ]
)
