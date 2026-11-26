// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FocusTrace",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FocusTrace", targets: ["FocusTrace"]),
        .executable(name: "focustrace-mcp", targets: ["FocusTraceMCP"])
    ],
    targets: [
        .target(name: "TrackingCore"),
        .executableTarget(name: "FocusTrace", dependencies: ["TrackingCore"]),
        .executableTarget(name: "FocusTraceMCP", dependencies: ["TrackingCore"]),
        .testTarget(name: "TrackingCoreTests", dependencies: ["TrackingCore"]),
        .testTarget(name: "FocusTraceTests", dependencies: ["FocusTrace"]),
        .testTarget(name: "FocusTraceMCPTests", dependencies: ["FocusTraceMCP", "TrackingCore"])
    ]
)
