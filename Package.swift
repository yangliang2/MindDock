// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MindDock",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MindDockCore",
            targets: ["MindDockCore"]
        ),
        .executable(
            name: "MindDockApp",
            targets: ["MindDockApp"]
        ),
        .executable(
            name: "MindDockTests",
            targets: ["MindDockCoreTests"]
        )
    ],
    targets: [
        .target(
            name: "MindDockCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Speech")
            ]
        ),
        .executableTarget(
            name: "MindDockApp",
            dependencies: ["MindDockCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "MindDockCoreTests",
            dependencies: ["MindDockCore"]
        )
    ]
)
