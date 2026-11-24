// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MsgOrb",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MsgOrb", targets: ["MsgOrb"])
    ],
    targets: [
        .executableTarget(
            name: "MsgOrb",
            path: "Sources/MsgOrb",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
