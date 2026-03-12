// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "vphone-cli",
    platforms: [
        .macOS(.v15),
    ],
    products: [],
    dependencies: [
        .package(path: "vendor/swift-argument-parser"),
        .package(path: "vendor/Dynamic"),
        .package(path: "vendor/libcapstone-spm"),
        .package(path: "vendor/libimg4-spm"),
        .package(path: "vendor/MachOKit"),
        .package(path: "vendor/AppleMobileDeviceLibrary"),
        .package(path: "vendor/AppleMobileDevice"),
        .package(path: "vendor/swift-subprocess"),
        .package(path: "vendor/swift-trustcache"),
    ],
    targets: [
        .target(
            name: "FirmwarePatcher",
            dependencies: [
                .product(name: "Capstone", package: "libcapstone-spm"),
                .product(name: "Img4tool", package: "libimg4-spm"),
                .product(name: "MachOKit", package: "MachOKit"),
            ],
            path: "sources/FirmwarePatcher"
        ),
        .target(
            name: "MobileRestoreCore",
            dependencies: [
                .product(name: "AppleMobileDeviceLibrary", package: "AppleMobileDeviceLibrary"),
                .product(name: "libimobiledevice", package: "AppleMobileDeviceLibrary"),
                .product(name: "libimobiledevice_glue", package: "AppleMobileDeviceLibrary"),
                .product(name: "libirecovery", package: "AppleMobileDeviceLibrary"),
                .product(name: "libplist", package: "AppleMobileDeviceLibrary"),
                .product(name: "libtatsu", package: "AppleMobileDeviceLibrary"),
                .product(name: "libusbmuxd", package: "AppleMobileDeviceLibrary"),
            ],
            path: "sources/MobileRestoreCore",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .define("HAVE_CONFIG_H"),
                .define("IDEVICERESTORE_NOMAIN"),
            ],
            linkerSettings: [
                .linkedLibrary("curl"),
                .linkedLibrary("m"),
                .linkedLibrary("z"),
            ]
        ),
        .executableTarget(
            name: "vphone-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Capstone", package: "libcapstone-spm"),
                .product(name: "Dynamic", package: "Dynamic"),
                .product(name: "libirecovery", package: "AppleMobileDeviceLibrary"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "TrustCache", package: "swift-trustcache"),
                .product(name: "Img4tool", package: "libimg4-spm"),
                "FirmwarePatcher",
                "MobileRestoreCore",
            ],
            path: "sources/vphone-cli",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(
            name: "FirmwarePatcherTests",
            dependencies: ["FirmwarePatcher"],
            path: "tests/FirmwarePatcherTests"
        ),
    ]
)
