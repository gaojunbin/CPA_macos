// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CPAStatusBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CPAStatusCore", targets: ["CPAStatusCore"]),
        .executable(name: "CPAStatusBar", targets: ["CPAStatusBar"]),
        .executable(name: "CPAUpdateInstaller", targets: ["CPAUpdateInstaller"])
    ],
    targets: [
        .target(
            name: "CPAStatusCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "CPAStatusBar",
            dependencies: ["CPAStatusCore"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "CPAUpdateInstaller",
            dependencies: ["CPAStatusCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "CPAStatusCoreTests",
            dependencies: ["CPAStatusCore"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
