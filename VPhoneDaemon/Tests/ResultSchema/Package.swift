// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResultSchemaCheck",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .target(
            name: "ResultSchemaKit",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(name: "ResultSchemaCheck", dependencies: ["ResultSchemaKit"]),
        .testTarget(name: "ResultSchemaCheckTests", dependencies: ["ResultSchemaKit"]),
    ]
)
