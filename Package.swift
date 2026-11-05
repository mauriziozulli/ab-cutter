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
        ),
        .executable(
            name: "SessionCutter",
            targets: ["SessionCutter"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ABCutter",
            path: "Sources/ABCutter",
            // The three Sound Matters faces, so a playout carries the house
            // type rather than whatever the system happens to have.
            resources: [.copy("Resources/Schriften")]
        ),
        // The lean sibling: record Pro Tools and both mixes, lay the film
        // over it, set the A/B switches and stills, export 4:5 and 9:16.
        .executableTarget(
            name: "SessionCutter",
            path: "Sources/SessionCutter",
            resources: [.copy("Resources/Schriften")]
        )
    ]
)
