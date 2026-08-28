// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "LoupeCore", targets: ["LoupeCore"]),
        .library(name: "LoupeUI", targets: ["LoupeUI"]),
    ],
    targets: [
        .target(name: "LoupeCore"),
        .target(name: "LoupeUI", dependencies: ["LoupeCore"]),
        .testTarget(name: "LoupeCoreTests", dependencies: ["LoupeCore"]),
        .testTarget(name: "LoupeUITests", dependencies: ["LoupeUI"]),
    ]
)
