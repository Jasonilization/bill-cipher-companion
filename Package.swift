// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bill",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Bill",
            path: "Sources/Bill",
            resources: [
                .copy("Resources/Sprites"),
                .copy("Resources/Dialogue")
            ]
        )
    ]
)
