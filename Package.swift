// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftFind",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SwiftFind", targets: ["SwiftFind"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(
            name: "SwiftFind",
            dependencies: ["CSQLite"],
            path: "Sources/SwiftFind",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
