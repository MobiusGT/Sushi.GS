// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SushiGS",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SushiGSKit", targets: ["SushiGSKit"]),
        .executable(name: "SushiGS", targets: ["SushiGS"]),
    ],
    targets: [
        // Pure Foundation models, pairing engine, log/warning parser, NDJSON protocol, and binary resolution.
        .target(
            name: "SushiGSKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Native macOS 26 SwiftUI app target with main-actor default isolation.
        .executableTarget(
            name: "SushiGS",
            dependencies: ["SushiGSKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "SushiGSKitTests",
            dependencies: ["SushiGSKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
