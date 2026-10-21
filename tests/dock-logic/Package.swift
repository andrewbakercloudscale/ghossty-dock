// swift-tools-version:5.10
import PackageDescription

// The sidebar's ordering, grouping and cost code, which only needs
// Foundation. Its sources are symlinks into vendor/ghostty, so run
// scripts/build-terminal.sh (or apply the patch) first.
let package = Package(
    name: "DockLogic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DockLogic"),
        .testTarget(name: "DockLogicTests", dependencies: ["DockLogic"]),
    ]
)
