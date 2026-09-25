// swift-tools-version: 6.2
import PackageDescription

// The Mac app (SwiftUI, AppKit, Supabase's Apple-only sign-in UI) is only
// part of the package when building on a Mac. Everywhere else -- Windows
// first -- the package is the core, its tests, and `grasp-check`.
#if os(macOS)
let appTargets: [Target] = [
    // App + views. Defaults every type in this target to @MainActor
    // (SE-0466), which removes most strict-concurrency friction in the
    // UI layer while GRASPCore stays explicitly nonisolated.
    .executableTarget(
        name: "GRASP",
        dependencies: [
            "GRASPCore",
            .product(name: "Supabase", package: "supabase-swift"),
        ],
        path: "Sources/GRASP",
        swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
]
#else
let appTargets: [Target] = []
#endif

let package = Package(
    name: "GRASP",
    platforms: [.macOS(.v14), .iOS(.v17)],
    // The core as a library, so the iOS app's Xcode project (GRASPiOS/)
    // can build on the same ingest, study engine and sync code.
    products: [
        .library(name: "GRASPCore", targets: ["GRASPCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        // .pptx is a zip of XML parts (slide text, speaker notes) -- this
        // is the one reader for that shape; PDF/docx both ride Apple's own
        // PDFKit/AppKit readers with no library needed.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        // Accounts and sync: Supabase's auth (Google / email sign-in, with
        // the session kept in the Keychain) and its REST client for the
        // one table sync reads and writes.
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
        // CryptoKit's API for platforms without CryptoKit (Windows, Linux):
        // content hashes and PIN hashing.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        // Pure logic: ingest, store, and the study engine (FSRS scheduling,
        // Learn mode, test generation, answer grading). Stays nonisolated
        // and Sendable-only so it is unit-testable off the main actor and
        // has no dependency on SwiftUI/AppKit.
        .target(
            name: "GRASPCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.windows, .linux])),
            ],
            path: "Sources/GRASPCore"
        ),
        // A command-line smoke test of the core -- database, import, study
        // engine, overview maths -- for a platform with no GRASP app yet.
        // `swift run grasp-check` on Windows answers "does the core work
        // here?" before any interface is built on it.
        .executableTarget(
            name: "grasp-check",
            dependencies: ["GRASPCore"],
            path: "Sources/grasp-check"
        ),
        .testTarget(
            name: "GRASPCoreTests",
            dependencies: [
                "GRASPCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Tests/GRASPCoreTests",
            resources: [.copy("Fixtures")]
        )
    ] + appTargets
)
