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
    ],
    targets: [
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
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "sources/VPhoneCore",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        // Everything that touches a running guest: the machine, its window and
        // menus, the vsock channel and the host device bridges. It is a library
        // so the only executable holding the private virtualization
        // entitlements can stay as small as an argument parse and an
        // NSApplication run loop.
        .target(
            name: "VPhoneVMKit",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Dynamic", package: "Dynamic"),
                "VPhoneCore",
            ],
            path: "sources/VPhoneVMKit",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        // The only binary signed with sources/vphone.entitlements.
        .executableTarget(
            name: "vphone-vm",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "VPhoneCore",
                "VPhoneVMKit",
            ],
            path: "sources/vphone-vm"
        ),
        // The user-facing entry point. Note it depends on neither VPhoneVMKit
        // nor any of the five frameworks above: it never builds a machine, it
        // starts vphone-vm. Adding a dependency on the kit here would quietly
        // undo the split, so don't.
        .executableTarget(
            name: "vphone-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "FirmwarePatcher",
                "VPhoneCore",
            ],
            path: "sources/vphone-cli"
        ),
        // Opens a short AMFI window so vphone-vm can be exec'd. Plain C against
        // the SDK; no third-party anything.
        .executableTarget(
            name: "vphone-letmein",
            path: "sources/vphone-letmein",
            linkerSettings: [
                .linkedFramework("Foundation"),
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
    ]
)
