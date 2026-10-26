// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ActLog",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ActLog",
            path: "Sources/ActLog",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
