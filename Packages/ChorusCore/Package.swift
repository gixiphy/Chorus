// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChorusCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ChorusCore", targets: ["ChorusCore"])
    ],
    targets: [
        .target(name: "ChorusCore"),
        .testTarget(name: "ChorusCoreTests", dependencies: ["ChorusCore"])
    ]
)
