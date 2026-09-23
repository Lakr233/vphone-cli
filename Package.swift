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
        .package(path: "vendor/libarchive.xcframework"),
    ],
    targets: [
        .target(
            name: "FirmwarePatcher",
            dependencies: [
                .product(name: "Capstone", package: "libcapstone-spm"),
                .product(name: "Img4tool", package: "libimg4-spm"),
                .product(name: "MachOKit", package: "MachOKit"),
                // The cryptex patcher re-signs what it rewrites. That used to be
                // three `runProcess("/opt/homebrew/bin/ldid", …)` calls, which is
                // the one thing in this package that made `make check-aux` fail.
                "VPhoneSign",
                // And it unpacks three archives onto the volume it is building,
                // which were the last three `runProcess("/usr/bin/tar", …)` calls
                // anywhere in the package.
                "VPhoneArchive",
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
        // Archive reading and writing: the one place that knows how ownership,
        // permissions and path safety differ between unpacking onto a mounted
        // guest volume and unpacking into a host temp directory. Replaces
        // gtar, bsdtar, unzip and zstd, which between them were four external
        // programs and, for anything .zst, a Homebrew install.
        .target(
            name: "VPhoneArchive",
            dependencies: [
                .product(name: "LibArchive", package: "libarchive.xcframework"),
                "VPhoneCore",
            ],
            path: "sources/VPhoneArchive"
        ),
        // Ad-hoc and PKCS#12 Mach-O code signing, byte for byte what ldid
        // writes. It replaces ldid, which is the only program this project
        // shipped that links Homebrew (libcrypto.3, libplist-2.0.4) and so
        // the only one that failed `make check-aux`. Nothing here is outside
        // the system frameworks: CryptoKit for the hashes, Security for the
        // PKCS#12 and the CMS.
        .target(
            name: "VPhoneSign",
            path: "sources/VPhoneSign",
            linkerSettings: [
                .linkedFramework("Security"),
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
        // undo the split, so don't. VPhoneArchive is fine and is why `vm export`
        // still works here: it sits above VPhoneCore and pulls in neither
        // Virtualization nor AppKit.
        .executableTarget(
            name: "vphone-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "FirmwarePatcher",
                "VPhoneArchive",
                "VPhoneCore",
            ],
            path: "sources/vphone-cli"
        ),
        .executableTarget(
            name: "vphone-archive",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "VPhoneArchive",
                "VPhoneCore",
            ],
            path: "sources/vphone-archive"
        ),
        // A `vphone-letmein` target stood here: a C program that wrote amfid's
        // __TEXT to open a short window for vphone-vm. It cannot work on a host
        // where `vm.cs_system_enforcement` is 1 — the dirtied page is exactly
        // what gets amfid SIGKILLed — and opening an AMFI window is the user's
        // decision to make, not this project's. See "SIP/AMFI Relaxation" in
        // README.md for the two routes that do work.
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
            name: "VPhoneArchiveTests",
            dependencies: ["VPhoneArchive"],
            path: "tests/VPhoneArchiveTests"
        ),
        .testTarget(
            name: "VPhoneSignTests",
            dependencies: ["VPhoneSign"],
            path: "tests/VPhoneSignTests"
        ),
    ]
)
