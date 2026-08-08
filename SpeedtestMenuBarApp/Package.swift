// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpeedtestMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SpeedtestMenuBar",
            path: "Sources/SpeedtestMenuBar"
        )
    ]
)
