// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AllOfMacOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AllOfMacOS", targets: ["AllOfMacOS"]),
    ],
    targets: [
        .executableTarget(
            name: "AllOfMacOS",
            path: "AllOfMacOS",
            exclude: ["App/Info.plist", "AllOfMacOS.entitlements", "Assets.xcassets"]
        ),
        .testTarget(
            name: "AllOfMacOSTests",
            dependencies: ["AllOfMacOS"],
            path: "AllOfMacOSTests"
        ),
    ]
)
