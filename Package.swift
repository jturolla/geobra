// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Geobra",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Geobra", targets: ["Geobra"]),
        .library(name: "GeobraCore", targets: ["GeobraCore"])
    ],
    targets: [
        .target(name: "GeobraCore"),
        .executableTarget(
            name: "Geobra",
            dependencies: ["GeobraCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "GeobraCoreTests", dependencies: ["GeobraCore"]),
        .testTarget(name: "GeobraAppTests", dependencies: ["Geobra", "GeobraCore"])
    ]
)
