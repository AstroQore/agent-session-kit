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
    // Swift and Rust are peer implementation lanes under implementations/.
    // Explicit paths keep this manifest at the repository root so every
    // consumer's git URL, exact pin, and `import AgentSessionKit` are
    // unchanged by the layout.
    targets: [
        // Discovery, parsing, indexing, and the MCP transport. Extracted
        // from Vibe Bar, where this code grew up inside the app target;
        // it is still on the Swift 5 language mode because the adapters
        // were written against it. Migrating is its own change.
        .target(
            name: "AgentSessionKit",
            path: "implementations/swift/Sources/AgentSessionKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Live views over the same stores — file-system watching and
        // incremental tailing. Swift 6 language mode from the start,
        // because nothing here predates strict concurrency.
        .target(
            name: "AgentSessionLive",
            dependencies: ["AgentSessionKit"],
            path: "implementations/swift/Sources/AgentSessionLive"
        ),
        .testTarget(
            name: "AgentSessionKitTests",
            dependencies: ["AgentSessionKit"],
            path: "implementations/swift/Tests/AgentSessionKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `Fixtures/` holds sample source records, one directory per
        // harness. Declared as a resource rather than excluded so the
        // adapters landing later can read a sample through `Bundle.module`
        // instead of reconstructing a path from `#filePath`.
        .testTarget(
            name: "AgentSessionLiveTests",
            dependencies: ["AgentSessionLive"],
            path: "implementations/swift/Tests/AgentSessionLiveTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
