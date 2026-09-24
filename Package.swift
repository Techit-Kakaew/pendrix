// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pendrix",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.0"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", from: "0.23.0"),
    ],
    targets: [
        .executableTarget(
            name: "Pendrix",
            dependencies: [
                "Highlightr",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
            ],
            path: "Sources/Pendrix",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
