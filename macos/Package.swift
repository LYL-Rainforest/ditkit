// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DitKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DitKit", targets: ["DitKit"]),
        .library(name: "DitKitCore", targets: ["DitKitCore"]),
    ],
    targets: [
        .target(name: "xxhash", path: "Sources/xxhash"),
        .target(name: "DitKitCore", dependencies: ["xxhash"], path: "Sources/DitKitCore"),
        .executableTarget(name: "DitKit", dependencies: ["DitKitCore"], path: "Sources/DitKit"),
        .testTarget(name: "DitKitTests", dependencies: ["DitKitCore"], path: "Tests/DitKitTests"),
    ]
)
