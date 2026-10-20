// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacSecondMonitor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        // Shared wire protocol, also used by the iOS client.
        .library(name: "MSMProtocol", targets: ["MSMProtocol"]),
        // Client core (connection, decoding), also used by the iOS client.
        .library(name: "MSMClientKit", targets: ["MSMClientKit"]),
        .executable(name: "MacSecondMonitor", targets: ["MacSecondMonitor"]),
        .executable(name: "msm", targets: ["msm"]),
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayKit",
            path: "Sources/CGVirtualDisplayKit"
        ),
        .target(
            name: "MSMProtocol"
        ),
        .target(
            name: "MSMClientKit",
            dependencies: ["MSMProtocol"]
        ),
        .target(
            name: "MSMHost",
            dependencies: ["MSMProtocol", "CGVirtualDisplayKit"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "MacSecondMonitor",
            dependencies: ["MSMHost"]
        ),
        .executableTarget(
            name: "msm",
            dependencies: ["MSMHost", "MSMClientKit"]
        ),
        .testTarget(
            name: "MSMProtocolTests",
            dependencies: ["MSMProtocol"]
        ),
        .testTarget(
            name: "MSMHostTests",
            dependencies: ["MSMHost", "MSMClientKit"]
        ),
        .testTarget(
            name: "MSMClientKitTests",
            dependencies: ["MSMClientKit"]
        ),
    ]
)
