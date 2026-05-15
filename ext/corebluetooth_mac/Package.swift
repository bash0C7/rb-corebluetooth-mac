// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "CoreBluetoothMac",
    platforms: [.macOS("11.0")],
    products: [
        .library(name: "CoreBluetoothMac", type: .dynamic, targets: ["CoreBluetoothMac"])
    ],
    targets: [
        .target(name: "CoreBluetoothMac", path: "Sources/CoreBluetoothMac")
    ]
)
