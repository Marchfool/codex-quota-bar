// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexQuotaBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexQuotaBar", targets: ["CodexQuotaBar"]),
        .library(name: "CodexQuotaCore", targets: ["CodexQuotaCore"])
    ],
    targets: [
        .target(
            name: "CodexQuotaCore",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "CodexQuotaBar",
            dependencies: ["CodexQuotaCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "CodexQuotaCoreTestRunner",
            dependencies: ["CodexQuotaCore"]
        )
    ]
)
