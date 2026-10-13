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
        )
    ]
)
