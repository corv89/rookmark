// swift-tools-version: 6.0
import PackageDescription

// rookmark — CLI bookmark organizer powered by the macOS-bundled on-device
// Foundation Models LLM. macOS 26+ / Apple Silicon ONLY: the FoundationModels
// framework is not available on Linux or Intel Macs, so there is intentionally
// no other platform/architecture in this matrix.
let package = Package(
    name: "rookmark",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "rookmark", targets: ["rookmark"]),
        .executable(name: "RookmarkApp", targets: ["RookmarkApp"]),
        .library(name: "RookmarkKit", targets: ["RookmarkKit"]),
        .library(name: "EvalKit", targets: ["EvalKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Thin CLI layer. Holds zero domain logic — only argument parsing and
        // wiring into RookmarkKit so the core stays unit-testable.
        .executableTarget(
            name: "rookmark",
            dependencies: [
                "RookmarkKit",
                "EvalKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/rookmark"
        ),
        // Testable core. The only target that imports FoundationModels.
        .target(
            name: "RookmarkKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/RookmarkKit",
            linkerSettings: [
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("FoundationModels"),
            ]
        ),
        // SwiftUI app. Deliberately a SwiftPM executable rather than an Xcode
        // app project: it runs unsandboxed, which is what lets it read another
        // browser's profile without entitlements. The App Store would require
        // sandboxing and cost exactly that capability.
        .executableTarget(
            name: "RookmarkApp",
            dependencies: ["RookmarkKit"],
            path: "Sources/RookmarkApp"
        ),
        .target(
            name: "EvalKit",
            dependencies: [
                "RookmarkKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/EvalKit"
        ),
        .testTarget(
            name: "RookmarkKitTests",
            dependencies: ["RookmarkKit"],
            path: "Tests/RookmarkKitTests"
        ),
        .testTarget(
            name: "EvalKitTests",
            dependencies: ["EvalKit"],
            path: "Tests/EvalKitTests"
        ),
    ]
)
