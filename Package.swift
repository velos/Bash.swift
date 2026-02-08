// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BashSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "BashSwift",
            targets: ["BashSwift"]
        ),
        .library(
            name: "BashSQLite",
            targets: ["BashSQLite"]
        ),
        .library(
            name: "BashPython",
            targets: ["BashPython"]
        ),
        .library(
            name: "BashGit",
            targets: ["BashGit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .binaryTarget(
            name: "Clibgit2",
            url: "https://github.com/flaboy/static-libgit2/releases/download/1.8.5/Clibgit2.xcframework.zip",
            checksum: "f62a6760f8c2ff1a82e4fb80c69fe2aa068458c7619f5b98c53c71579f72f9c7"
        ),
        .target(
            name: "BashSwift",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "BashSQLite",
            dependencies: [
                "BashSwift",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "BashPython",
            dependencies: [
                "BashSwift",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "BashGit",
            dependencies: [
                "BashSwift",
                "Clibgit2",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedLibrary("iconv")
            ]
        ),
        .testTarget(
            name: "BashSwiftTests",
            dependencies: ["BashSwift"]
        ),
        .testTarget(
            name: "BashSQLiteTests",
            dependencies: [
                "BashSwift",
                "BashSQLite",
            ]
        ),
        .testTarget(
            name: "BashPythonTests",
            dependencies: [
                "BashSwift",
                "BashPython",
            ]
        ),
        .testTarget(
            name: "BashGitTests",
            dependencies: [
                "BashSwift",
                "BashGit",
            ]
        ),
    ]
)
