// swift-tools-version:6.0
import Foundation
import PackageDescription

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let nativeSources = ["unarchive.m", "vphoned_install.m", "vphoned_keychain.m", "vphoned_vcam.m", "vphoned_native.m"]
let gitHash = ProcessInfo.processInfo.environment["GIT_HASH"] ?? "unknown"

let package = Package(
    name: "vphoned",
    platforms: [.iOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/owngoal-dev/icli.git", exact: "0.6.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.83.0"),
    ],
    targets: [
        .target(
            name: "VphonedNative",
            path: ".",
            sources: nativeSources,
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("vendor/libarchive"),
                .define("VPHONED_BUILD_HASH", to: "\"\(gitHash)\""),
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedLibrary("archive"),
                .linkedLibrary("sqlite3"),
                .linkedFramework("Foundation"),
                .linkedFramework("Security"),
                .linkedFramework("CoreServices"),
            ],
        ),
        .executableTarget(
            name: "vphoned",
            dependencies: [
                "VphonedNative",
                .product(name: "IcliKit", package: "icli"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: "Daemon",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip_dylibs"])],
        ),
    ],
)
