// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeChatExporter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WeChatExporter", targets: ["WeChatExporter"]),
    ],
    targets: [
        .executableTarget(
            name: "WeChatExporter",
            path: "Sources/WeChatExporter",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
