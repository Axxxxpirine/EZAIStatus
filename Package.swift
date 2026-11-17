// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EZAIStatus",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EZAIStatus", targets: ["EZAIStatus"]),
    ],
    dependencies: [
        // Mises à jour automatiques signées (EdDSA), framework officiel.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "EZAIStatusCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "EZAIStatus",
            dependencies: ["EZAIStatusCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "ezaistatus-probe",
            dependencies: ["EZAIStatusCore"]
        ),
        .testTarget(
            name: "EZAIStatusCoreTests",
            dependencies: ["EZAIStatusCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
