// swift-tools-version: 6.2
import PackageDescription

// GRASP for Windows. Its own package, next to the main one rather than in
// it, so SwiftCrossUI never becomes a dependency of the Mac and iPhone
// builds. The screens are SwiftCrossUI, which draws native WinUI controls
// on Windows -- and AppKit ones on a Mac, which is how it's developed and
// tried out between Windows runs. Everything below the screens is the
// same GRASPCore the other apps use.
let package = Package(
    name: "GRASPWindows",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "GRASP", path: ".."),
        // Pinned to main for its WinUI button and menu fixes, which are
        // newer than the 0.9.0 release.
        .package(url: "https://github.com/moreSwift/swift-cross-ui.git",
                 revision: "0f3ec3958b79cdc39a1a3e604516b71ab33a9043"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "GRASPWindows",
            dependencies: [
                .product(name: "GRASPCore", package: "GRASP"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
