// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wacomd",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "wacomd", targets: ["wacomd"]),
        .executable(name: "wacomd-config", targets: ["wacomd-config"])
    ],
    targets: [
        // Shared schema + config-on-disk logic. Used by both the daemon
        // and the menu-bar configurator so the two stay in sync.
        .target(
            name: "WacomdShared",
            path: "Sources/WacomdShared"
        ),
        .executableTarget(
            name: "wacomd",
            dependencies: ["WacomdShared"],
            path: "Sources/wacomd"
        ),
        .executableTarget(
            name: "wacomd-config",
            dependencies: ["WacomdShared"],
            path: "Sources/wacomd-config"
        ),
        .testTarget(
            name: "wacomdTests",
            dependencies: ["wacomd"],
            path: "Tests/wacomdTests"
        )
    ]
)
