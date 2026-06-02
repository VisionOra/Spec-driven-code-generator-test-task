// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "messaging-cli",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0")
    ],
    targets: [
        .executableTarget(
            name: "messaging-cli",
            dependencies: [.product(name: "SQLite", package: "SQLite.swift")],
            path: "Sources/messaging-cli"
        )
    ]
)
