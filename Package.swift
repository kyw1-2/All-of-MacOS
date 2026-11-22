// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AllOfMacOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AllOfMacOS", targets: ["AllOfMacOS"]),
    ],
    targets: [
        // 7.10: macOS 27's menu bar visibility restriction (see its header).
        .target(
            name: "AOMMenuBarNative",
            path: "AOMMenuBarNative",
            exclude: ["LICENSE-HiddenBar.txt"],
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        .executableTarget(
            name: "AllOfMacOS",
            dependencies: ["AOMMenuBarNative"],
            path: "AllOfMacOS",
            exclude: ["App/Info.plist", "App/AllOfMacOS.sdef", "AllOfMacOS.entitlements", "Assets.xcassets"]
        ),
        .testTarget(
            name: "AllOfMacOSTests",
            dependencies: ["AllOfMacOS"],
            path: "AllOfMacOSTests"
        ),
    ]
)
