// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OrchestratorGUI",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "OrchestratorGUI",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OrchestratorGUITests",
            dependencies: ["OrchestratorGUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
