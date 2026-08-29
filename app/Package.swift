// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacApp",
            path: "Sources/MacApp"
        )
    ]
)
