// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GhosttyDock",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that decides: reading state files, matching sessions to tabs, status. No UI.
        .target(name: "DockCore"),
        // The sidebar app. Thin: it polls Ghostty, renders DockCore's rows and forwards clicks.
        .executableTarget(name: "GhosttyDock", dependencies: ["DockCore"]),
        .testTarget(name: "DockCoreTests", dependencies: ["DockCore"]),
    ]
)
