// swift-tools-version:6.1
import PackageDescription

let applePlatforms: [Platform] = [.iOS, .macOS]

let package = Package(
    name: "MicDropKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MicDropCore", targets: ["MicDropCore"]),
        .library(name: "MicDropIdentity", targets: ["MicDropIdentity"]),
        .library(name: "MicDropTransport", targets: ["MicDropTransport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
    ],
    targets: [
        .target(
            name: "MicDropCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "MicDropIdentity",
            dependencies: [
                "MicDropCore",
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "MicDropTransport",
            dependencies: [
                "MicDropCore",
                "MicDropIdentity",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(
                    name: "NIOTransportServices",
                    package: "swift-nio-transport-services",
                    condition: .when(platforms: applePlatforms)
                ),
            ]
        ),
        .target(name: "MicDropTestSupport", path: "Tests/MicDropTestSupport"),
        .testTarget(name: "MicDropCoreTests", dependencies: ["MicDropCore", "MicDropTestSupport"]),
        .testTarget(name: "MicDropIdentityTests", dependencies: ["MicDropIdentity", "MicDropTestSupport"]),
        .testTarget(
            name: "MicDropTransportTests",
            dependencies: [
                "MicDropTransport",
                "MicDropTestSupport",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
