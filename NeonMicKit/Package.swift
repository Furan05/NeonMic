// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NeonMicKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NeonMicKit", targets: ["NeonMicKit"])
    ],
    targets: [
        .target(name: "NeonMicKit"),
        .testTarget(
            name: "NeonMicKitTests",
            dependencies: ["NeonMicKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
