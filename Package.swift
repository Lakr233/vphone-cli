// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "vphone-cli",
    platforms: [
        .macOS(.v15),
    ],
    products: [],
    // Resolved by SwiftPM, not carried as submodules. Every one of these was a
    // `.package(path: "vendor/…")` over a checkout this repository pinned by
    // commit, which meant a `git submodule update` before any build and a tree
    // that could sit at an unreleased commit — MachOKit was four commits past
    // 0.46.1, Dynamic two past 1.2.0. A URL and a version says the same thing
    // in one line, and `Package.resolved` records exactly what was built.
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/mhdhejazi/Dynamic.git", from: "1.2.0"),
        // The one that cannot be a version: its CoreCapstone target carries
        // `.unsafeFlags(["-Wno-shorten-64-to-32"])`, and SwiftPM refuses unsafe
        // flags in a dependency resolved by version — a branch requirement is
        // allowed to carry them. Drop that flag upstream and this becomes
        // `from:` like the rest.
        .package(url: "https://github.com/Lakr233/libcapstone-spm.git", branch: "main"),
        .package(url: "https://github.com/Lakr233/libimg4-spm.git", from: "0.1.1"),
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "0.1.1"),
        .package(url: "https://github.com/p-x9/MachOKit.git", from: "0.52.2"),
        // libimobiledevice, its glue, libplist, libusbmuxd, libtatsu and
        // OpenSSL, as prebuilt xcframeworks. This is what replaces
        // pymobiledevice3: the restore backend's whole dependency stack
        // arrives through SwiftPM instead of a pip install into a venv, and
        // the C targets below include its headers directly.
        .package(url: "https://github.com/Lakr233/AppleMobileDeviceLibrary.git", from: "1.0.1790070576"),
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
        // libirecovery 1.3.1, vendored. It talks to iBoot/iBSS over USB, which
        // is the half of a restore that `idevicerestore` does not get from
        // libimobiledevice, and it is not in AppleMobileDeviceLibrary. Upstream
        // ships it as an autotools project, so the only things here that are
        // not upstream's own bytes are config.h — which says what `./configure`
        // would have concluded on macOS — and this stanza.
        //
        // The backend is IOKit, not libusb: on a host whose SDK has
        // IOKit/usb/IOUSBLib.h, upstream's configure.ac picks IOKit and never
        // looks for libusb. That is deliberate here too, because a libusb
        // backend would mean a Homebrew dylib in the link, and `make check-aux`
        // exists to keep those out.
        .target(
            name: "MobileRecoveryCore",
            dependencies: [
                // libplist, libimobiledevice-glue (collection.h, thread.h) and
                // libusbmuxd, as prebuilt xcframeworks.
                .product(name: "AppleMobileDeviceLibrary", package: "AppleMobileDeviceLibrary"),
            ],
            path: "sources/MobileRecoveryCore",
            // Upstream's LGPL-2.1 text. It ships with the source; it does not
            // compile, so SwiftPM has to be told it is not an input.
            exclude: ["COPYING"],
            publicHeadersPath: "include",
            cSettings: [
                // config.h sits beside libirecovery.c rather than in include/,
                // so it stays out of the module's umbrella and no dependent
                // ever sees a PACKAGE_VERSION it did not ask for.
                .headerSearchPath("."),
                .define("HAVE_CONFIG_H", to: "1"),
                // Upstream's `--enable-static --disable-shared` case, which is
                // what a SwiftPM target is: IRECV_API collapses to nothing
                // instead of a dllexport or a visibility attribute.
                .define("IRECV_STATIC", to: "1"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // idevicerestore, vendored. This is the restore backend itself — the
        // thing scripts/pymobiledevice3_bridge.py has been standing in for,
        // and the last reason this repository has a venv. Upstream is a
        // program; here it is a library, built with IDEVICERESTORE_NOMAIN so
        // its main(), getopt table and signal handling are excluded, and
        // driven through sources/MobileRestoreCore/include/vphone_restore_bridge.h.
        //
        // Two files in this target are not upstream's and both say so at the
        // top: config.h, which is what ./configure would have written, and the
        // libzip stub. libzip is the one PKG_CHECK_MODULES dependency with no
        // counterpart here, and linking Homebrew's copy would put an absolute
        // path in the closure that `make check-aux` gate 1 rejects. It is only
        // reachable when reading a .ipsw archive or re-signing a .bbfw, and
        // this project restores from an extracted directory onto a device with
        // no baseband — zip.h has the full argument.
        .target(
            name: "MobileRestoreCore",
            dependencies: [
                // <libirecovery.h>: DFU and recovery over USB.
                "MobileRecoveryCore",
                // libimobiledevice, its glue, libplist, libusbmuxd, libtatsu.
                .product(name: "AppleMobileDeviceLibrary", package: "AppleMobileDeviceLibrary"),
            ],
            path: "sources/MobileRestoreCore",
            // Upstream's LGPL-2.1 text, which ships with the source and does
            // not compile.
            exclude: ["COPYING"],
            publicHeadersPath: "include",
            cSettings: [
                // Reaches config.h and the libzip stub, both of which sit
                // beside the .c files rather than in include/ — include/ is
                // the generated module's umbrella, and neither a second
                // PACKAGE_VERSION nor a fake <zip.h> belongs in a header a
                // dependent imports. include/ holds the bridge header alone.
                .headerSearchPath("."),
                .define("HAVE_CONFIG_H", to: "1"),
                .define("IRECV_STATIC", to: "1"),
            ],
            linkerSettings: [
                // Both from /usr/lib: libcurl.4.dylib for the TSS request and
                // the firmware download, libz.1.dylib for the gzipped .shsh
                // and the compressed BuildManifest members. These two are on
                // check_aux.sh's system whitelist; nothing else is linked.
                .linkedLibrary("curl"),
                .linkedLibrary("z"),
            ]
        ),
        // The Swift face of the two C targets above, and what actually
        // replaces scripts/pymobiledevice3_bridge.py: probe for a DFU/recovery
        // endpoint, fetch a SHSH blob, drive a restore. Three of the Python's
        // four commands — `usbmux-list` had no call site anywhere in this
        // repository and is not ported.
        //
        // It links libz because it has to undo one thing idevicerestore does:
        // `-t/--shsh` writes a GZIPPED binary plist, and the `.shsh` this
        // project has always written beside a VM is a plain one. /usr/lib/
        // libz.1.dylib is on check_aux.sh's system whitelist.
        .target(
            name: "VPhoneRestore",
            dependencies: [
                "MobileRecoveryCore",
                "MobileRestoreCore",
            ],
            path: "sources/VPhoneRestore",
            linkerSettings: [
                .linkedLibrary("z"),
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
        //
        // VPhoneRestore is the line that ends the venv: `restore`, `vm create`
        // and `make restore*` reach it directly instead of spawning a Python.
        // It is also what finally puts libirecovery, idevicerestore, libcurl
        // and libz inside .build/vphone-cli.app, where `make check-aux` gate 1
        // can see them.
        .executableTarget(
            name: "vphone-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "FirmwarePatcher",
                "VPhoneArchive",
                "VPhoneCore",
                "VPhoneRestore",
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
        // Everything here runs without a device attached: argument parsing,
        // the restore-tree rules, the .shsh naming and the C struct the
        // options turn into. What needs a phone in DFU is not tested, and
        // saying so is better than a test that only looks like one.
        .testTarget(
            name: "VPhoneRestoreTests",
            dependencies: ["VPhoneRestore"],
            path: "tests/VPhoneRestoreTests"
        ),
    ]
)
