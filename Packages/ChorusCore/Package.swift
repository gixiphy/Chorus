// swift-tools-version: 6.0
import PackageDescription

// Cloud agents run Linux. CryptoKit is a system module on macOS; swift-crypto
// supplies the same API there. Mac builds keep an empty dependency list.
#if os(Linux)
let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
]
let chorusCoreDependencies: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),
]
let chorusCoreTestDependencies: [Target.Dependency] = [
    "ChorusCore",
    .product(name: "Crypto", package: "swift-crypto"),
]
#else
let packageDependencies: [Package.Dependency] = []
let chorusCoreDependencies: [Target.Dependency] = []
let chorusCoreTestDependencies: [Target.Dependency] = ["ChorusCore"]
#endif

let package = Package(
    name: "ChorusCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ChorusCore", targets: ["ChorusCore"])
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "ChorusCore", dependencies: chorusCoreDependencies),
        .testTarget(name: "ChorusCoreTests", dependencies: chorusCoreTestDependencies)
    ]
)
