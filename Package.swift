// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiskTrace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DiskTraceCore", targets: ["DiskTraceCore"]),
        .executable(name: "disktrace-agent", targets: ["DiskTraceAgent"]),
    ],
    targets: [
        .target(
            name: "DiskTraceCore",
            path: "Sources/DiskTraceCore"
        ),
        .executableTarget(
            name: "DiskTraceAgent",
            dependencies: ["DiskTraceCore"],
            path: "Sources/DiskTraceAgent"
        ),
        .executableTarget(
            name: "DiskTraceApp",
            dependencies: ["DiskTraceCore"],
            path: "Sources/DiskTraceApp"
        ),
        .testTarget(
            name: "DiskTraceCoreTests",
            dependencies: ["DiskTraceCore"],
            path: "Tests/DiskTraceCoreTests"
        ),
    ]
)
