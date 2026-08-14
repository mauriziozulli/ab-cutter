// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ABCutter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ABCutter",
            targets: ["ABCutter"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ABCutter",
            path: "Sources/ABCutter"
        )
    ]
)
