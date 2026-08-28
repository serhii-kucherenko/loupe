// swift-tools-version: 5.9
import PackageDescription

// A separate package on purpose.
//
// Linking a SwiftUI executable from SwiftPM needs a compiler flag (see below), and
// `unsafeFlags` makes a package unusable as a dependency. Loupe is meant to be
// adopted by other people's apps, so the flag lives here, in the example, and the
// SDK package stays clean.
let package = Package(
    name: "LoupeDemo",
    platforms: [.macOS(.v13)],
    // Named explicitly: SwiftPM takes a path dependency's identity from its
    // directory name, and this checkout does not have to be called "loupe".
    dependencies: [.package(name: "loupe", path: "../..")],
    targets: [
        .executableTarget(
            name: "LoupeDemo",
            dependencies: [
                .product(name: "LoupeCore", package: "loupe"),
                .product(name: "LoupeUI", package: "loupe"),
            ],
            swiftSettings: [
                // SwiftUI re-exports SwiftUICore, and a plain executable is not an
                // allowed client of it. Turning off the autolink entry lets the app
                // link SwiftUI the way an app bundle would.
                .unsafeFlags(["-Xfrontend", "-disable-autolink-framework",
                              "-Xfrontend", "SwiftUICore"])
            ]),
        // Renders the overlay to PNG without a screen, so what it looks like can be
        // checked in CI and in a pull request rather than described in prose.
        .executableTarget(
            name: "LoupeSnapshots",
            dependencies: [
                .product(name: "LoupeCore", package: "loupe"),
                .product(name: "LoupeUI", package: "loupe"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-autolink-framework",
                              "-Xfrontend", "SwiftUICore"])
            ]),
    ]
)
