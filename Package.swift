// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hexa",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Hexa", targets: ["Hexa"])],
    targets: [
        .target(name: "HexaCore"),
        .executableTarget(name: "Hexa", dependencies: ["HexaCore"], resources: [.copy("Resources/Welcome.bin")]),
        .testTarget(name: "HexaCoreTests", dependencies: ["HexaCore"]),
        .testTarget(name: "HexaAppTests", dependencies: ["Hexa"])
    ]
)
