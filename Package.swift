// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GuliKitUpdater",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NS58Core", targets: ["NS58Core"]),
        .library(name: "USBTransport", targets: ["USBTransport"]),
        .executable(name: "GuliKitUpdater", targets: ["GuliKitUpdater"]),
        .executable(name: "gulikit", targets: ["GuliKitCLI"]),
    ],
    targets: [
        .target(name: "NS58Core"),
        .target(name: "USBTransport", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [
            .linkedFramework("Foundation"), .linkedFramework("IOKit"), .linkedFramework("IOUSBHost"),
        ]),
        .executableTarget(name: "GuliKitUpdater", dependencies: ["NS58Core", "USBTransport"],
            linkerSettings: [.linkedFramework("AccessoryAccess"), .linkedFramework("AppKit")]),
        .executableTarget(name: "GuliKitCLI", dependencies: ["NS58Core"]),
        .testTarget(name: "NS58CoreTests", dependencies: ["NS58Core"]),
    ]
)
