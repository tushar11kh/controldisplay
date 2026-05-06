// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DisplayToggleBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DisplayToggleBar", targets: ["DisplayToggleBar"])
    ],
    targets: [
        .executableTarget(
            name: "DisplayToggleBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .unsafeFlags([
                    "-F/System/Library/PrivateFrameworks",
                    "-framework", "SkyLight",
                    "-framework", "DisplayServices"
                ])
            ]
        )
    ]
)
