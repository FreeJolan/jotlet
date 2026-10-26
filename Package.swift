// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jotlet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Jotlet", targets: ["Jotlet"])],
    targets: [
        .target(name: "JotletCore"),
        .executableTarget(name: "Jotlet", dependencies: ["JotletCore"]),
        .testTarget(name: "JotletCoreTests", dependencies: ["JotletCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
