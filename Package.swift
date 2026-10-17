// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "CloudingBar",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "CloudingBar",
            path: "Sources/CloudingBar"
        ),
        .executableTarget(
            name: "CloudingBarTap",
            path: "Sources/CloudingBarTap"
        ),
        .executableTarget(
            name: "CloudingBarHook",
            path: "Sources/CloudingBarHook"
        ),
    ]
)
