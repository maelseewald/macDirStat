// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacDirStat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacDirStat",
            path: "Sources/MacDirStat",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
