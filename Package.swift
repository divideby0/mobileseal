// swift-tools-version:6.2
// Pinned toolchain: Apple Swift 6.2 (swiftlang-6.2.0.19.9) — see .swift-version.
// CI must invoke this exact toolchain; the ~Copyable public API surface was
// feasibility-spiked against it (goals/CED-10-private-photo-vault, WS A.2).
import PackageDescription

let package = Package(
    name: "VaultCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "VaultCore", targets: ["VaultCore"]),
        .executable(name: "argon2-bench", targets: ["Argon2Bench"]),
    ],
    dependencies: [
        // Sole crypto dependency (spec §5.1): libsodium via Swift-Sodium.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.9.1"),
    ],
    targets: [
        .target(
            name: "VaultCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Clibsodium", package: "swift-sodium"),
            ]
        ),
        .executableTarget(
            name: "Argon2Bench",
            dependencies: [
                "VaultCore",
                .product(name: "Clibsodium", package: "swift-sodium"),
            ]
        ),
        .testTarget(
            name: "VaultCoreTests",
            dependencies: ["VaultCore"],
            exclude: ["CompileFail/Fixtures"],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
