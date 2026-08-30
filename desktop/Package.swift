// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mihari",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // 実行可能ターゲットはテストから import できないため、中身はすべて MihariCore に置く。
        .executableTarget(
            name: "Mihari",
            dependencies: ["MihariCore"],
            path: "Sources/Mihari"
        ),
        .target(
            name: "MihariCore",
            path: "Sources/MihariCore",
            // ディレクトリ階層 pets/<id>/pet.json と voice/<kind>/<NN>.m4a をそのまま保つため
            // .process ではなく .copy にする。
            resources: [
                .copy("Resources/pets"),
                .copy("Resources/voice"),
            ]
        ),
        .testTarget(
            name: "MihariCoreTests",
            dependencies: ["MihariCore"],
            path: "Tests/MihariCoreTests"
        ),
    ]
)
