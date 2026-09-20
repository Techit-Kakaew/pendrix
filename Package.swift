// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pendrix",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Pendrix",
            dependencies: ["Highlightr"],
            path: "Sources/Pendrix",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
