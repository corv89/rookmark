// swift-tools-version: 6.0
import PackageDescription

// lazybm — CLI bookmark organizer powered by the macOS-bundled on-device
// Foundation Models LLM. macOS 26+ / Apple Silicon ONLY: the FoundationModels
// framework is not available on Linux or Intel Macs, so there is intentionally
// no other platform/architecture in this matrix.
let package = Package(
    name: "lazybm",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "lazybm", targets: ["lazybm"]),
        .library(name: "LazyBookmarksKit", targets: ["LazyBookmarksKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Thin CLI layer. Holds zero domain logic — only argument parsing and
        // wiring into LazyBookmarksKit so the core stays unit-testable.
        .executableTarget(
            name: "lazybm",
            dependencies: [
                "LazyBookmarksKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/lazybm"
        ),
        // Testable core. The only target that imports FoundationModels.
        .target(
            name: "LazyBookmarksKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/LazyBookmarksKit",
            linkerSettings: [
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("FoundationModels"),
            ]
        ),
        .testTarget(
            name: "LazyBookmarksKitTests",
            dependencies: ["LazyBookmarksKit"],
            path: "Tests/LazyBookmarksKitTests"
        ),
    ]
)
