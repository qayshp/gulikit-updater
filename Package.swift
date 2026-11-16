// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GuliKitUpdater",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NS58Core", targets: ["NS58Core"]),
        .library(name: "USBTransport", targets: ["USBTransport"]),
        .library(name: "FirmwareDownload", targets: ["FirmwareDownload"]),
        .library(name: "AccessoryReproCore", targets: ["AccessoryReproCore"]),
        .executable(name: "GuliKitUpdater", targets: ["GuliKitUpdater"]),
        .executable(name: "gulikit", targets: ["GuliKitCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(name: "NS58Core"),
        .target(name: "AccessoryReproCore"),
        .target(name: "FirmwareDownload", dependencies: [
            "NS58Core", .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
        .target(name: "USBTransport", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [
            .linkedFramework("Foundation"), .linkedFramework("IOKit"), .linkedFramework("IOUSBHost"),
        ]),
        .executableTarget(name: "GuliKitUpdater", dependencies: ["NS58Core", "USBTransport", "FirmwareDownload"],
            linkerSettings: [.linkedFramework("AccessoryAccess"), .linkedFramework("AppKit")]),
        .executableTarget(name: "GuliKitCLI", dependencies: ["NS58Core", "FirmwareDownload"]),
        .testTarget(name: "FirmwareDownloadTests", dependencies: ["FirmwareDownload", "NS58Core"]),
        .testTarget(name: "NS58CoreTests", dependencies: ["NS58Core"]),
        .testTarget(name: "USBTransportTests", dependencies: ["USBTransport"]),
        .testTarget(name: "AccessoryReproCoreTests", dependencies: ["AccessoryReproCore"]),
    ]
)
