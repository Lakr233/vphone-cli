// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "vphone-cli",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "VPhoneCameraShared", targets: ["VPhoneCameraShared"]),
        .executable(name: "vphone-camera-extension", targets: ["vphone-camera-extension"]),
        .executable(name: "vphone-camera-installer", targets: ["vphone-camera-installer"]),
    ],
    dependencies: [
        .package(path: "vendor/swift-argument-parser"),
        .package(path: "vendor/Dynamic"),
        .package(path: "vendor/libcapstone-spm"),
        .package(path: "vendor/libimg4-spm"),
        .package(path: "vendor/MachOKit"),
    ],
    targets: [
        .target(
            name: "VPhoneCameraShared",
            path: "sources/VPhoneCameraShared"
        ),
        .executableTarget(
            name: "vphone-camera-extension",
            dependencies: ["VPhoneCameraShared"],
            path: "sources/vphone-camera-extension",
            linkerSettings: [
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "vphone-camera-installer",
            dependencies: ["VPhoneCameraShared"],
            path: "sources/vphone-camera-installer",
            linkerSettings: [
                .linkedFramework("SystemExtensions"),
            ]
        ),
        .target(
            name: "FirmwarePatcher",
            dependencies: [
                .product(name: "Capstone", package: "libcapstone-spm"),
                .product(name: "Img4tool", package: "libimg4-spm"),
                .product(name: "MachOKit", package: "MachOKit"),
                "VPhoneCore",
            ],
            path: "sources/FirmwarePatcher"
        ),
        .target(
            name: "VPhoneCore",
            path: "sources/VPhoneCore",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(
            name: "vphone-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Dynamic", package: "Dynamic"),
                "FirmwarePatcher",
                "VPhoneCore",
                "VPhoneCameraShared",
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
        .testTarget(
            name: "VPhoneCoreTests",
            dependencies: ["VPhoneCore"],
            path: "tests/VPhoneCoreTests"
        ),
        .testTarget(
            name: "VPhoneCameraSharedTests",
            dependencies: ["VPhoneCameraShared"],
            path: "tests/VPhoneCameraSharedTests"
        ),
    ]
)
