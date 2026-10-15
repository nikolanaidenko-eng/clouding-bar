// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeBar",
            path: "Sources/ClaudeBar"
        ),
        .executableTarget(
            name: "ClaudeBarTap",
            path: "Sources/ClaudeBarTap"
        ),
        .executableTarget(
            name: "ClaudeBarHook",
            path: "Sources/ClaudeBarHook"
        ),
    ]
)
