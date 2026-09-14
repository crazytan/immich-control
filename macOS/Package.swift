// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImmichControl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ImmichCore", targets: ["ImmichCore"]),
        .executable(name: "ImmichControl", targets: ["ImmichControlApp"]),
        .executable(name: "immich-helper", targets: ["ImmichHelper"]),
    ],
    targets: [
        .target(name: "ImmichCore"),
        .executableTarget(name: "ImmichControlApp", dependencies: ["ImmichCore"]),
        .executableTarget(name: "ImmichHelper", dependencies: ["ImmichCore"]),
        .testTarget(name: "ImmichCoreTests", dependencies: ["ImmichCore"]),
    ]
)
