// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-libp2p",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        // MARK: - Core
        .library(name: "P2PCore", targets: ["P2PCore"]),

        // MARK: - Transport
        .library(name: "P2PTransport", targets: ["P2PTransport"]),
        .library(name: "P2PTransportTCP", targets: ["P2PTransportTCP"]),
        .library(name: "P2PTransportQUIC", targets: ["P2PTransportQUIC"]),
        .library(name: "P2PTransportMemory", targets: ["P2PTransportMemory"]),

        // MARK: - Security
        .library(name: "P2PSecurity", targets: ["P2PSecurity"]),
        .library(name: "P2PSecurityNoise", targets: ["P2PSecurityNoise"]),
        .library(name: "P2PSecurityPlaintext", targets: ["P2PSecurityPlaintext"]),

        // MARK: - Mux
        .library(name: "P2PMux", targets: ["P2PMux"]),
        .library(name: "P2PMuxYamux", targets: ["P2PMuxYamux"]),

        // MARK: - Negotiation
        .library(name: "P2PNegotiation", targets: ["P2PNegotiation"]),

        // MARK: - Discovery
        .library(name: "P2PDiscovery", targets: ["P2PDiscovery"]),
        .library(name: "P2PDiscoveryMDNS", targets: ["P2PDiscoveryMDNS"]),
        .library(name: "P2PDiscoverySWIM", targets: ["P2PDiscoverySWIM"]),

        // MARK: - Protocols
        .library(name: "P2PProtocols", targets: ["P2PProtocols"]),
        .library(name: "P2PIdentify", targets: ["P2PIdentify"]),
        .library(name: "P2PPing", targets: ["P2PPing"]),
        .library(name: "P2PGossipSub", targets: ["P2PGossipSub"]),
        .library(name: "P2PCircuitRelay", targets: ["P2PCircuitRelay"]),
        .library(name: "P2PDCUtR", targets: ["P2PDCUtR"]),
        .library(name: "P2PAutoNAT", targets: ["P2PAutoNAT"]),
        .library(name: "P2PKademlia", targets: ["P2PKademlia"]),

        // MARK: - Integration
        .library(name: "P2P", targets: ["P2P"]),

        // MARK: - Examples
        .executable(name: "PingPongDemo", targets: ["PingPongDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.91.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.8.0"),
        .package(url: "https://github.com/1amageek/swift-mDNS.git", from: "1.0.0"),
        .package(url: "https://github.com/1amageek/swift-SWIM.git", from: "1.0.0"),
        .package(url: "https://github.com/1amageek/swift-nio-udp.git", from: "1.0.0"),
        .package(path: "../swift-quic"),
    ],
    targets: [
        // MARK: - Core
        .target(
            name: "P2PCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Core/P2PCore"
        ),
        .testTarget(
            name: "P2PCoreTests",
            dependencies: ["P2PCore"],
            path: "Tests/Core/P2PCoreTests"
        ),

        // MARK: - Transport (protocol definitions only, no NIO dependency)
        .target(
            name: "P2PTransport",
            dependencies: ["P2PCore", "P2PMux"],
            path: "Sources/Transport/P2PTransport"
        ),
        .target(
            name: "P2PTransportTCP",
            dependencies: [
                "P2PTransport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/Transport/TCP"
        ),
        .target(
            name: "P2PTransportQUIC",
            dependencies: [
                "P2PTransport",
                "P2PCore",
                "P2PMux",
                .product(name: "QUIC", package: "swift-quic"),
            ],
            path: "Sources/Transport/QUIC"
        ),
        .target(
            name: "P2PTransportMemory",
            dependencies: ["P2PTransport"],
            path: "Sources/Transport/Memory"
        ),
        .testTarget(
            name: "P2PTransportTests",
            dependencies: ["P2PTransport", "P2PTransportMemory"],
            path: "Tests/Transport/P2PTransportTests"
        ),
        .testTarget(
            name: "P2PTransportQUICTests",
            dependencies: [
                "P2PTransportQUIC",
                "P2PCore",
                .product(name: "QUIC", package: "swift-quic"),
            ],
            path: "Tests/Transport/QUICTests"
        ),

        // MARK: - Security
        .target(
            name: "P2PSecurity",
            dependencies: ["P2PCore"],
            path: "Sources/Security/P2PSecurity"
        ),
        .target(
            name: "P2PSecurityNoise",
            dependencies: [
                "P2PSecurity",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/Security/Noise"
        ),
        .target(
            name: "P2PSecurityPlaintext",
            dependencies: ["P2PSecurity"],
            path: "Sources/Security/Plaintext"
        ),
        .testTarget(
            name: "P2PSecurityTests",
            dependencies: ["P2PSecurity", "P2PSecurityPlaintext"],
            path: "Tests/Security/P2PSecurityTests"
        ),
        .testTarget(
            name: "P2PSecurityNoiseTests",
            dependencies: ["P2PSecurityNoise", "P2PTransportMemory"],
            path: "Tests/Security/NoiseTests"
        ),
        .testTarget(
            name: "P2PSecurityPlaintextTests",
            dependencies: ["P2PSecurityPlaintext", "P2PSecurity", "P2PCore"],
            path: "Tests/Security/PlaintextTests"
        ),

        // MARK: - Mux
        .target(
            name: "P2PMux",
            dependencies: ["P2PCore"],
            path: "Sources/Mux/P2PMux"
        ),
        .target(
            name: "P2PMuxYamux",
            dependencies: ["P2PMux"],
            path: "Sources/Mux/Yamux"
        ),
        .testTarget(
            name: "P2PMuxTests",
            dependencies: ["P2PMux", "P2PMuxYamux"],
            path: "Tests/Mux/P2PMuxTests"
        ),
        .testTarget(
            name: "P2PMuxYamuxTests",
            dependencies: ["P2PMuxYamux"],
            path: "Tests/Mux/YamuxTests"
        ),

        // MARK: - Negotiation
        .target(
            name: "P2PNegotiation",
            dependencies: ["P2PCore"],
            path: "Sources/Negotiation/P2PNegotiation"
        ),
        .testTarget(
            name: "P2PNegotiationTests",
            dependencies: ["P2PNegotiation", "P2PCore"],
            path: "Tests/Negotiation/P2PNegotiationTests"
        ),

        // MARK: - Discovery
        .target(
            name: "P2PDiscovery",
            dependencies: ["P2PCore"],
            path: "Sources/Discovery/P2PDiscovery"
        ),
        .target(
            name: "P2PDiscoveryMDNS",
            dependencies: [
                "P2PDiscovery",
                "P2PCore",
                .product(name: "mDNS", package: "swift-mDNS"),
            ],
            path: "Sources/Discovery/MDNS"
        ),
        .target(
            name: "P2PDiscoverySWIM",
            dependencies: [
                "P2PDiscovery",
                "P2PCore",
                .product(name: "SWIM", package: "swift-SWIM"),
                .product(name: "NIOUDPTransport", package: "swift-nio-udp"),
            ],
            path: "Sources/Discovery/SWIM"
        ),
        .testTarget(
            name: "P2PDiscoveryTests",
            dependencies: ["P2PDiscovery", "P2PDiscoverySWIM", "P2PDiscoveryMDNS"],
            path: "Tests/Discovery/P2PDiscoveryTests"
        ),

        // MARK: - Protocols
        .target(
            name: "P2PProtocols",
            dependencies: ["P2PCore", "P2PMux"],
            path: "Sources/Protocols/P2PProtocols"
        ),
        .target(
            name: "P2PIdentify",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/Identify"
        ),
        .target(
            name: "P2PPing",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/Ping"
        ),
        .testTarget(
            name: "P2PIdentifyTests",
            dependencies: ["P2PIdentify", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/IdentifyTests"
        ),
        .testTarget(
            name: "P2PPingTests",
            dependencies: ["P2PPing", "P2PCore", "P2PProtocols"],
            path: "Tests/Protocols/PingTests"
        ),
        .target(
            name: "P2PGossipSub",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/GossipSub"
        ),
        .testTarget(
            name: "P2PGossipSubTests",
            dependencies: ["P2PGossipSub", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/GossipSubTests"
        ),
        .target(
            name: "P2PCircuitRelay",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux", "P2PTransport"],
            path: "Sources/Protocols/CircuitRelay"
        ),
        .testTarget(
            name: "P2PCircuitRelayTests",
            dependencies: ["P2PCircuitRelay", "P2PTransportMemory"],
            path: "Tests/Protocols/CircuitRelayTests"
        ),
        .target(
            name: "P2PDCUtR",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/DCUtR"
        ),
        .testTarget(
            name: "P2PDCUtRTests",
            dependencies: ["P2PDCUtR", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/DCUtRTests"
        ),
        .target(
            name: "P2PAutoNAT",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/AutoNAT"
        ),
        .testTarget(
            name: "P2PAutoNATTests",
            dependencies: ["P2PAutoNAT", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/AutoNATTests"
        ),
        .target(
            name: "P2PKademlia",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/Kademlia"
        ),
        .testTarget(
            name: "P2PKademliaTests",
            dependencies: ["P2PKademlia"],
            path: "Tests/Protocols/KademliaTests"
        ),

        // MARK: - Integration (depends only on protocols, not implementations)
        .target(
            name: "P2P",
            dependencies: [
                "P2PCore",
                "P2PTransport",
                "P2PSecurity",
                "P2PMux",
                "P2PNegotiation",
                "P2PDiscovery",
                "P2PProtocols",
                "P2PPing",
            ],
            path: "Sources/Integration/P2P"
        ),
        .testTarget(
            name: "P2PTests",
            dependencies: [
                "P2P",
                "P2PTransportMemory",
                "P2PSecurityPlaintext",
                "P2PMuxYamux",
                "P2PPing",
            ],
            path: "Tests/Integration/P2PTests"
        ),

        // MARK: - Examples
        .executableTarget(
            name: "PingPongDemo",
            dependencies: [
                "P2P",
                "P2PTransportTCP",
                "P2PSecurityPlaintext",
                "P2PMuxYamux",
            ],
            path: "Examples/PingPongDemo"
        ),
    ]
)
