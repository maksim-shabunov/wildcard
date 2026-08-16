// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wildcard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "WildcardKit",
            resources: [.process("Catalog/Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WildcardApp",
            dependencies: ["WildcardKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "wildcard",
            dependencies: ["WildcardKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WildcardKitTests",
            dependencies: ["WildcardKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
