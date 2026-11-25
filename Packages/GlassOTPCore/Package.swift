// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GlassOTPCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "GlassOTPCore",
            targets: ["GlassOTPCore"]
        ),
    ],
    targets: [
        .target(
            name: "GlassOTPCore",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "GlassOTPCoreTests",
            dependencies: ["GlassOTPCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
