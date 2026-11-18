// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Helm",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Helm",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HelmTests",
            dependencies: ["Helm"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
