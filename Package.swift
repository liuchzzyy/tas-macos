// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TAS",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TASCore", targets: ["TASCore"]),
        .executable(name: "tas", targets: ["tas"]),
        .executable(name: "TASDesktop", targets: ["TASApp"])
    ],
    dependencies: [.package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.10.0")],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .systemLibrary(name: "CZlib", pkgConfig: "zlib"),
        .systemLibrary(name: "CCommonCrypto"),
        .target(name: "TASCore", dependencies: [
            "CSQLite", "CZlib", "CryptoSwift",
            .target(name: "CCommonCrypto", condition: .when(platforms: [.macOS]))
        ], resources: [.copy("schema.sql")]),
        .executableTarget(name: "tas", dependencies: ["TASCore"]),
        .executableTarget(name: "TASApp", dependencies: ["TASCore"]),
        .testTarget(name: "TASCoreTests", dependencies: ["TASCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
