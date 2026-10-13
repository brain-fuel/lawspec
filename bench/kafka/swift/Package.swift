// swift-tools-version: 6.2
// The generated project's package, with the benchmark driver as an executable.
import PackageDescription

let package = Package(
    name: "Example",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "KafkaBench", targets: ["KafkaBench"]),
    ],
    targets: [
        .target(name: "LawSpecRuntime", path: "lawspec/LawSpecRuntime"),
        .target(name: "LawSpecTesting", dependencies: ["LawSpecRuntime"], path: "lawspec/LawSpecTesting"),
        .target(name: "App", dependencies: ["LawSpecRuntime"], path: "src"),
        .testTarget(name: "AppTests", dependencies: ["App", "LawSpecRuntime", "LawSpecTesting"], path: "tests"),
        .executableTarget(name: "KafkaBench", dependencies: ["App", "LawSpecRuntime"], path: "bench"),
    ]
)
