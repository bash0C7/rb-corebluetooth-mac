// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "CoreBluetoothMac",
    platforms: [.macOS(.v27)],
    products: [
        .library(
            name: "CoreBluetoothMac",
            type: .dynamic,
            targets: ["CoreBluetoothMac"]
        ),
    ],
    targets: [
        .target(
            name: "CoreBluetoothMac"
        ),
    ]
)
