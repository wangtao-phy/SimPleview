// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.
// Managed by VSXcode — changes will be overwritten

import PackageDescription

let package = Package(
    name: "SimPleview",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v27),
        .macOS(.v27)
    ],
    products: [
        .library(
            name: "SimPleview",
            targets: ["SimPleview"]
        )
    ],
    targets: [
        .target(
            name: "SimPleview",
            path: "SimPleview",
            resources: [.process("Assets.xcassets")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ]
)
