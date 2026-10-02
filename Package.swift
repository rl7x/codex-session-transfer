// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSessionTransfer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexSessionTransfer", targets: ["CodexSessionTransfer"])
    ],
    targets: [
        .target(
            name: "CodexSessionTransferCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CodexSessionTransfer",
            dependencies: ["CodexSessionTransferCore"]
        ),
        .testTarget(
            name: "CodexSessionTransferTests",
            dependencies: ["CodexSessionTransferCore"]
        )
    ]
)
