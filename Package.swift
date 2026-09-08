// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GRASP",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        // Pure logic: ingest, store, and the study engine (FSRS scheduling,
        // Learn mode, test generation, answer grading). Stays nonisolated
        // and Sendable-only so it is unit-testable off the main actor and
        // has no dependency on SwiftUI/AppKit.
        .target(
            name: "GRASPCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/GRASPCore"
        ),
        // App + views. Defaults every type in this target to @MainActor
        // (SE-0466), which removes most strict-concurrency friction in the
        // UI layer while GRASPCore stays explicitly nonisolated.
        .executableTarget(
            name: "GRASP",
            dependencies: ["GRASPCore"],
            path: "Sources/GRASP",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "GRASPCoreTests",
            dependencies: ["GRASPCore"],
            path: "Tests/GRASPCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
