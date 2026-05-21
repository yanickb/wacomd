// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wacomd",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "wacomd", targets: ["wacomd"])
    ],
    targets: [
        .executableTarget(
            name: "wacomd",
            path: "Sources/wacomd"
        ),
        .testTarget(
            name: "wacomdTests",
            dependencies: ["wacomd"],
            path: "Tests/wacomdTests"
        )
    ]
)
