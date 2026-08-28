// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "LoupeCore", targets: ["LoupeCore"]),
        .library(name: "LoupeUI", targets: ["LoupeUI"]),
        // Opt-in. A host that wants capture only never takes this, and `LoupeCore`
        // keeps no opinion about issue trackers.
        .library(name: "LoupeLinear", targets: ["LoupeLinear"]),
    ],
    targets: [
        .target(name: "LoupeCore"),
        .target(name: "LoupeUI", dependencies: ["LoupeCore"]),
        // Depends on LoupeUI, not the other way round. A host that wants capture
        // only takes LoupeUI and never sees Linear; the dependency that matters is
        // the one that does not exist.
        .target(name: "LoupeLinear", dependencies: ["LoupeCore", "LoupeUI"]),
        .testTarget(name: "LoupeCoreTests", dependencies: ["LoupeCore"]),
        .testTarget(name: "LoupeUITests", dependencies: ["LoupeUI"]),
        .testTarget(name: "LoupeLinearTests", dependencies: ["LoupeLinear"]),
    ]
)
