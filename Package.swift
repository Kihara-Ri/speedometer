// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Speedometer",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SpeedCore", targets: ["SpeedCore"]),
        .executable(name: "speed-replay", targets: ["SpeedReplay"])
    ],
    targets: [
        .target(name: "SpeedCore"),
        .executableTarget(name: "SpeedReplay", dependencies: ["SpeedCore"]),
        .testTarget(name: "SpeedCoreTests", dependencies: ["SpeedCore"])
    ]
)
