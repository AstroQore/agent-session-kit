// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "agent-session-kit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "AgentSessionKit", targets: ["AgentSessionKit"]),
        .library(name: "AgentSessionLive", targets: ["AgentSessionLive"])
    ],
    targets: [
        // Discovery, parsing, indexing, and the MCP transport. Extracted
        // from Vibe Bar, where this code grew up inside the app target;
        // it is still on the Swift 5 language mode because the adapters
        // were written against it. Migrating is its own change.
        .target(
            name: "AgentSessionKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Live views over the same stores — file-system watching and
        // incremental tailing. Swift 6 language mode from the start,
        // because nothing here predates strict concurrency.
        .target(
            name: "AgentSessionLive",
            dependencies: ["AgentSessionKit"]
        ),
        .testTarget(
            name: "AgentSessionKitTests",
            dependencies: ["AgentSessionKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentSessionLiveTests",
            dependencies: ["AgentSessionLive"]
        )
    ]
)
