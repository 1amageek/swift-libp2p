// swift-tools-version: 6.2

import PackageDescription

// Keep the default `swift test` contract deterministic and bounded:
// correctness tests run by default, while Docker-backed interop and CPU-heavy
// benchmarks are opt-in release lanes.
let includesInteropTests = Context.environment["SWIFT_LIBP2P_ENABLE_INTEROP_TESTS"] == "1"
let includesBenchmarks = Context.environment["SWIFT_LIBP2P_ENABLE_BENCHMARKS"] == "1"

// Embedded toggle controls the experimental Embedded feature + WMO for the
// Embedded-clean cores. Lifetimes is enabled in BOTH modes because Span-returning
// members of the P2PCoreBytes dependency require @_lifetime.
let embeddedEnabled = Context.environment["P2P_CORE_EMBEDDED"] == "1"

let coreSettings: [SwiftSetting] = {
    var s: [SwiftSetting] = [.enableExperimentalFeature("Lifetimes")]
    if embeddedEnabled {
        s += [.enableExperimentalFeature("Embedded"), .unsafeFlags(["-wmo"])]
    }
    return s
}()

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
        .library(name: "LibP2PCore", targets: ["LibP2PCore"]),
        .library(name: "P2PCore", targets: ["P2PCore"]),

        // MARK: - libp2p node (seam-based [UInt8] data path; host + Embedded)
        .library(name: "LibP2PNode", targets: ["LibP2PNode"]),

        // MARK: - Transport
        .library(name: "P2PTransport", targets: ["P2PTransport"]),
        .library(name: "P2PTransportSecured", targets: ["P2PTransportSecured"]),
        .library(name: "P2PTransportTCP", targets: ["P2PTransportTCP"]),
        .library(name: "P2PTransportQUIC", targets: ["P2PTransportQUIC"]),
        .library(name: "P2PTransportWebRTC", targets: ["P2PTransportWebRTC"]),
        .library(name: "P2PTransportWebSocket", targets: ["P2PTransportWebSocket"]),
        .library(name: "P2PTransportMemory", targets: ["P2PTransportMemory"]),

        // MARK: - Security
        .library(name: "P2PSecurity", targets: ["P2PSecurity"]),
        .library(name: "P2PCertificate", targets: ["P2PCertificate"]),
        .library(name: "P2PSecurityNoise", targets: ["P2PSecurityNoise"]),
        .library(name: "P2PSecurityPlaintext", targets: ["P2PSecurityPlaintext"]),
        .library(name: "P2PSecurityTLS", targets: ["P2PSecurityTLS"]),
        .library(name: "P2PPnet", targets: ["P2PPnet"]),

        // MARK: - Mux
        .library(name: "P2PMux", targets: ["P2PMux"]),
        .library(name: "P2PMuxYamux", targets: ["P2PMuxYamux"]),
        .library(name: "P2PMuxMplex", targets: ["P2PMuxMplex"]),

        // MARK: - Negotiation
        .library(name: "P2PNegotiation", targets: ["P2PNegotiation"]),

        // MARK: - Discovery
        .library(name: "P2PDiscovery", targets: ["P2PDiscovery"]),
        .library(name: "P2PDiscoveryMDNS", targets: ["P2PDiscoveryMDNS"]),
        .library(name: "P2PDiscoverySWIM", targets: ["P2PDiscoverySWIM"]),
        .library(name: "P2PDiscoveryCYCLON", targets: ["P2PDiscoveryCYCLON"]),
        .library(name: "P2PDiscoveryPlumtree", targets: ["P2PDiscoveryPlumtree"]),
        .library(name: "P2PDiscoveryBeacon", targets: ["P2PDiscoveryBeacon"]),
        .library(name: "P2PDiscoveryWiFiBeacon", targets: ["P2PDiscoveryWiFiBeacon"]),

        // MARK: - NAT
        .library(name: "P2PNAT", targets: ["P2PNAT"]),

        // MARK: - Protocols
        .library(name: "P2PProtocols", targets: ["P2PProtocols"]),
        .library(name: "P2PIdentify", targets: ["P2PIdentify"]),
        .library(name: "P2PPing", targets: ["P2PPing"]),
        .library(name: "P2PGossipSub", targets: ["P2PGossipSub"]),
        .library(name: "P2PCircuitRelay", targets: ["P2PCircuitRelay"]),
        .library(name: "P2PDCUtR", targets: ["P2PDCUtR"]),
        .library(name: "P2PAutoNAT", targets: ["P2PAutoNAT"]),
        .library(name: "P2PKademlia", targets: ["P2PKademlia"]),
        .library(name: "P2PPlumtree", targets: ["P2PPlumtree"]),
        .library(name: "P2PRendezvous", targets: ["P2PRendezvous"]),
        .library(name: "P2PHTTP", targets: ["P2PHTTP"]),
        .library(name: "P2PTransportWebTransport", targets: ["P2PTransportWebTransport"]),
        .library(name: "P2PRuntime", targets: ["P2PRuntime"]),

        // MARK: - Integration
        .library(name: "P2P", targets: ["P2P"]),

        // MARK: - Examples
        .executable(name: "PingPongDemo", targets: ["PingPongDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.91.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.8.0"),
        .package(url: "https://github.com/1amageek/swift-mDNS.git", from: "1.2.2"),
        .package(url: "https://github.com/1amageek/swift-SWIM.git", from: "1.2.2"),
        .package(url: "https://github.com/1amageek/swift-nio-udp.git", from: "1.1.3"),
        .package(url: "https://github.com/1amageek/swift-quic.git", from: "1.3.2"),
        .package(url: "https://github.com/1amageek/swift-tls.git", from: "1.3.1"),
        .package(url: "https://github.com/1amageek/swift-webrtc.git", from: "1.5.1"),
        .package(url: "https://github.com/1amageek/swift-p2p-core.git", from: "0.1.0"),
        // The unified crypto provider (`DefaultCryptoProvider`: host swift-crypto /
        // Embedded BoringSSL). Required by the Embedded node target to specialise
        // the Embedded-clean Noise / QUIC facade at a concrete crypto seam.
        .package(url: "https://github.com/1amageek/swift-p2p-crypto.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "P2PTestSupport",
            path: "Tests/Support/P2PTestSupport"
        ),

        // MARK: - Core
        // Embedded-clean codec core (dual-build: host + Embedded). No Foundation,
        // no NIO, no Crypto, no `any`. The first decomposition slice: unsigned
        // varint (LEB128), multihash framing, Base58, hex, and the protobuf wire
        // helpers, all over [UInt8] / P2PCoreBytes.
        .target(
            name: "LibP2PCore",
            dependencies: [
                .product(name: "P2PCoreBytes", package: "swift-p2p-core"),
                // Crypto seam (CryptoProvider/KeyAgreement/AEAD/KeyDerivation/...).
                // The Noise crypto state machine in this core is generic over
                // `C: CryptoProvider`; a concrete provider lives in the adapter.
                .product(name: "P2PCoreCrypto", package: "swift-p2p-core"),
            ],
            path: "Sources/LibP2PCore",
            swiftSettings: coreSettings
        ),
        // Foundation adapter over LibP2PCore: restores the historical Data/NIO
        // public API and keeps the Crypto/Logging/NIO-bearing core types.
        .target(
            name: "P2PCore",
            dependencies: [
                "LibP2PCore",
                .product(name: "P2PCoreFoundation", package: "swift-p2p-core"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            path: "Sources/Core/P2PCore",
            exclude: ["CONTEXT.md", "README.md"]
        ),
        .testTarget(
            name: "P2PCoreTests",
            dependencies: ["P2PCore", "LibP2PCore"],
            path: "Tests/Core/P2PCoreTests"
        ),

        // MARK: - libp2p node (seam-based [UInt8] data path; host + Embedded)
        // The minimal libp2p node's data-path foundation: a seam-based
        // `[UInt8]` transport→security→mux→negotiation slice that compiles on BOTH
        // host and Embedded Swift (`P2P_CORE_EMBEDDED=1 P2P_CRYPTO_EMBEDDED=1 swift
        // build --target LibP2PNode -c release`). It is ADDITIVE: the host
        // `P2P` / `Swarm` / host transports stay untouched and host-only. Builds
        // from the Embedded-clean cores only — `LibP2PCore` (Noise XX / multistream
        // codecs), the `QUIC` `[UInt8]` engine facade, and the crypto seam.
        .target(
            name: "LibP2PNode",
            dependencies: [
                "LibP2PCore",
                .product(name: "P2PCoreBytes", package: "swift-p2p-core"),
                .product(name: "P2PCoreCrypto", package: "swift-p2p-core"),
                .product(name: "P2PCoreTransport", package: "swift-p2p-core"),
                // The unified crypto provider (`DefaultCryptoProvider`).
                .product(name: "P2PCrypto", package: "swift-p2p-crypto"),
                // The DER-ECDSA TLS-signature provider (`QUICTLSSignatureProvider`):
                // DefaultCryptoProvider with ECDSA overridden to DER for the TLS
                // CertificateVerify + X.509 leaf wire (RFC 8446 §4.4.3). Dual-build.
                .product(name: "QUICTLSSignature", package: "swift-quic"),
                // The QUIC `[UInt8]` engine facade (`QUICEngineClient`).
                .product(name: "QUIC", package: "swift-quic"),
                .product(name: "QUICConnectionEngineCore", package: "swift-quic"),
                .product(name: "QUICConnectionCore", package: "swift-quic"),
                .product(name: "QUICWire", package: "swift-quic"),
                // The cored TLS 1.3 handshake FSMs + wire codecs the
                // libp2p-over-QUIC handshake driver runs (`QUICClientHandshake` /
                // `QUICServerHandshake` / `QUICClientAuthMachine` + message codecs).
                .product(name: "QUICTLSCore", package: "swift-quic"),
                // `QUICProtectionSuite` (the install-keys cipher seam).
                .product(name: "QUICPacketProtectionCore", package: "swift-quic"),
                // The Embedded-clean libp2p RPK certificate DER codec
                // (`LibP2PCertificateDER` / `LibP2PSignedKeyDER` / `LibP2PIdentity`
                // / `SubjectPublicKeyInfoDER`) for the QUIC TLS handshake identity.
                .product(name: "P2PCoreDER", package: "swift-p2p-core"),
            ],
            path: "Sources/LibP2PNode",
            swiftSettings: coreSettings
        ),
        .testTarget(
            name: "LibP2PNodeTests",
            dependencies: [
                "LibP2PNode",
                "LibP2PCore",
                .product(name: "P2PCoreBytes", package: "swift-p2p-core"),
                .product(name: "P2PCoreCrypto", package: "swift-p2p-core"),
                .product(name: "P2PCoreTransport", package: "swift-p2p-core"),
                // `LibP2PIdentity` PeerID derivation, for the Identify binding
                // cross-check in the Ping + Identify live test.
                .product(name: "P2PCoreDER", package: "swift-p2p-core"),
                .product(name: "P2PCrypto", package: "swift-p2p-crypto"),
                // `SystemWallClock` (host wall-clock seam) for the node cert timestamps.
                .product(name: "P2PCryptoFoundation", package: "swift-p2p-crypto"),
                // `QUICTLSSignatureProvider` (the node identity's DER-ECDSA provider).
                .product(name: "QUICTLSSignature", package: "swift-quic"),
                // The QUIC engine facade + cores the live loopback handshake test
                // drives (`QUICEngineClient` over a loopback `DatagramTransport`).
                .product(name: "QUIC", package: "swift-quic"),
                .product(name: "QUICConnectionEngineCore", package: "swift-quic"),
                .product(name: "QUICConnectionCore", package: "swift-quic"),
                .product(name: "QUICWire", package: "swift-quic"),
            ],
            path: "Tests/LibP2PNodeTests"
        ),

        // MARK: - Transport (protocol definitions only, no NIO dependency)
        .target(
            name: "P2PTransport",
            dependencies: ["P2PCore"],
            path: "Sources/Transport/P2PTransport"
        ),
        .target(
            name: "P2PTransportSecured",
            dependencies: ["P2PCore", "P2PTransport", "P2PMux"],
            path: "Sources/Transport/SecuredTransport"
        ),
        .target(
            name: "P2PTransportTCP",
            dependencies: [
                "P2PTransport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/Transport/TCP",
            exclude: ["CONTEXT.md"]
        ),
        .target(
            name: "P2PTransportQUIC",
            dependencies: [
                "P2PTransport",
                "P2PTransportSecured",
                "P2PCore",
                "P2PMux",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "QUIC", package: "swift-quic"),
                // The libp2p-over-QUIC certificate build/parse/verify goes
                // through the Embedded-clean minimal-DER codec (same path as the
                // swift-certificates RPK path) rather than swift-quic's
                // ASN1Builder / X509Certificate. swift-quic is still required for
                // the QUIC handshake itself.
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "P2PCoreDER", package: "swift-p2p-core"),
            ],
            path: "Sources/Transport/QUIC",
            exclude: ["CONTEXT.md"]
        ),
        .target(
            name: "P2PTransportWebRTC",
            dependencies: [
                "P2PTransport",
                "P2PTransportSecured",
                "P2PCore",
                "P2PMux",
                "P2PCertificate",
                .product(name: "Logging", package: "swift-log"),
                // The WebRTC product owns the DTLS certificate type
                // (`WebRTCCertificate`) and drives the DTLS handshake through
                // swift-tls's Tier-1 `TLS` facade internally. The former
                // `DTLSCore` product was demoted to a package target in the tls
                // facade redesign and is no longer importable here.
                .product(name: "WebRTC", package: "swift-webrtc"),
                // WebRTCMuxedConnection/WebRTCMuxedStream name the public
                // DataChannel type directly; keep that import explicit rather
                // than relying on transitive products from WebRTC.
                .product(name: "DataChannel", package: "swift-webrtc"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/Transport/WebRTC",
            exclude: ["CONTEXT.md"]
        ),
        .target(
            name: "P2PTransportWebSocket",
            dependencies: [
                "P2PTransport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/Transport/WebSocket",
            exclude: ["CONTEXT.md"]
        ),
        .target(
            name: "P2PTransportMemory",
            dependencies: ["P2PTransport"],
            path: "Sources/Transport/Memory",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PTransportTests",
            dependencies: [
                "P2PTestSupport",
                "P2PTransport",
                "P2PTransportMemory",
                "P2PTransportTCP",
                "P2PCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/Transport/P2PTransportTests"
        ),
        .testTarget(
            name: "P2PTransportQUICTests",
            dependencies: [
                "P2PTestSupport",
                "P2PTransportQUIC",
                "P2PCore",
                .product(name: "QUIC", package: "swift-quic"),
                // The P2PCoreDER-path cert tests build forged/valid libp2p leaf
                // certs directly with the minimal-DER primitives.
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "P2PCoreDER", package: "swift-p2p-core"),
            ],
            path: "Tests/Transport/QUICTests"
        ),
        .testTarget(
            name: "P2PTransportWebRTCTests",
            dependencies: [
                "P2PTestSupport",
                "P2PTransportWebRTC",
                "P2PTransport",
                "P2PTransportSecured",
                "P2PMux",
                "P2PCore",
                .product(name: "WebRTC", package: "swift-webrtc"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/Transport/WebRTCTests"
        ),
        .testTarget(
            name: "P2PTransportWebSocketTests",
            dependencies: [
                "P2PTestSupport",
                "P2PTransportWebSocket",
                "P2PTransport",
                "P2PCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: "Tests/Transport/WebSocketTests"
        ),

        // MARK: - Security
        .target(
            name: "P2PSecurity",
            dependencies: ["P2PCore"],
            path: "Sources/Security/P2PSecurity"
        ),
        .target(
            name: "P2PCertificate",
            dependencies: [
                "P2PCore",
                .product(name: "Crypto", package: "swift-crypto"),
                // M6b: the libp2p Raw-Public-Key (RPK) certificate build/parse/
                // verify goes through the Embedded-clean minimal-DER codec rather
                // than swift-certificates/SwiftASN1.
                .product(name: "P2PCoreDER", package: "swift-p2p-core"),
            ],
            path: "Sources/Security/Certificate"
        ),
        .target(
            name: "P2PSecurityNoise",
            dependencies: [
                "P2PSecurity",
                "LibP2PCore",
                .product(name: "Crypto", package: "swift-crypto"),
                // Crypto seam: the adapter provides `NoiseFoundationProvider`
                // (a host `CryptoProvider`) and specialises the Embedded-clean
                // Noise core in `LibP2PCore` at that provider.
                .product(name: "P2PCoreCrypto", package: "swift-p2p-core"),
                .product(name: "P2PCoreBytes", package: "swift-p2p-core"),
            ],
            path: "Sources/Security/Noise",
            exclude: ["CONTEXT.md", "README.md"]
        ),
        .target(
            name: "P2PSecurityPlaintext",
            dependencies: ["P2PSecurity"],
            path: "Sources/Security/Plaintext",
            exclude: ["CONTEXT.md"]
        ),
        .target(
            name: "P2PSecurityTLS",
            dependencies: [
                "P2PSecurity",
                "P2PCertificate",
                .product(name: "Crypto", package: "swift-crypto"),
                // Tier-1 TLS facade (`TLSClient`/`TLSServer`/`TLSConfiguration`).
                // Replaces the former `TLSCore`/`TLSRecord` products folded into
                // the facade in the tls redesign.
                .product(name: "TLS", package: "swift-tls"),
            ],
            path: "Sources/Security/TLS",
            exclude: ["CONTEXT.md"]
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
        .testTarget(
            name: "P2PCertificateTests",
            dependencies: [
                "P2PCertificate",
                "P2PCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "P2PCoreDER", package: "swift-p2p-core"),
            ],
            path: "Tests/Security/CertificateTests"
        ),
        .testTarget(
            name: "P2PSecurityTLSTests",
            dependencies: [
                "P2PSecurityTLS",
                "P2PCertificate",
                "P2PCore",
                .product(name: "TLS", package: "swift-tls"),
            ],
            path: "Tests/Security/TLSTests"
        ),
        .target(
            name: "P2PPnet",
            dependencies: [
                "P2PCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/Security/Pnet",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PPnetTests",
            dependencies: ["P2PPnet", "P2PCore"],
            path: "Tests/Security/PnetTests"
        ),

        // MARK: - Mux
        .target(
            name: "P2PMux",
            dependencies: [
                "P2PCore",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Sources/Mux/P2PMux"
        ),
        .target(
            name: "P2PMuxYamux",
            dependencies: ["P2PMux"],
            path: "Sources/Mux/Yamux",
            exclude: ["CONTEXT.md", "README.md"]
        ),
        .target(
            name: "P2PMuxMplex",
            dependencies: ["P2PMux"],
            path: "Sources/Mux/Mplex",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PMuxTests",
            dependencies: ["P2PMux", "P2PMuxYamux", "P2PMuxMplex"],
            path: "Tests/Mux/P2PMuxTests"
        ),
        .testTarget(
            name: "P2PMuxYamuxTests",
            dependencies: ["P2PMuxYamux"],
            path: "Tests/Mux/YamuxTests"
        ),
        .testTarget(
            name: "P2PMuxMplexTests",
            dependencies: ["P2PMuxMplex", "P2PTransportMemory", "P2PSecurityPlaintext"],
            path: "Tests/Mux/MplexTests"
        ),

        // MARK: - Negotiation
        .target(
            name: "P2PNegotiation",
            dependencies: ["P2PCore"],
            path: "Sources/Negotiation/P2PNegotiation",
            exclude: ["CONTEXT.md"]
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
                "P2PProtocols",
                .product(name: "MDNS", package: "swift-mDNS"),
                // The new MDNS facade vends `MDNSService.addresses` as
                // `P2PCoreTransport.IPAddress`; the codec consumes it directly.
                .product(name: "P2PCoreTransport", package: "swift-p2p-core"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Discovery/MDNS",
            exclude: ["CONTEXT.md"]
        ),
        .target(
            name: "P2PDiscoverySWIM",
            dependencies: [
                "P2PDiscovery",
                "P2PCore",
                "P2PProtocols",
                .product(name: "SWIM", package: "swift-SWIM"),
                // The Tier-3 `SWIMWire` codec product (`SWIMMessageCodec`) is not
                // re-exported by the `SWIM` facade; the transport adapter needs it
                // directly to (de)serialise SWIM messages on the wire.
                .product(name: "SWIMWire", package: "swift-SWIM"),
                .product(name: "NIOUDPTransport", package: "swift-nio-udp"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Discovery/SWIM",
            exclude: ["CONTEXT.md"]
        ),
        .target(
            name: "P2PDiscoveryCYCLON",
            dependencies: ["P2PDiscovery", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Sources/Discovery/CYCLON",
            exclude: ["CONTEXT.md"]
        ),
        .target(
            name: "P2PDiscoveryPlumtree",
            dependencies: [
                "P2PDiscovery", "P2PCore", "P2PMux", "P2PProtocols", "P2PPlumtree",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Discovery/Plumtree",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PDiscoveryTests",
            dependencies: ["P2PTestSupport", "P2PDiscovery", "P2PDiscoverySWIM", "P2PDiscoveryMDNS"],
            path: "Tests/Discovery/P2PDiscoveryTests"
        ),
        .testTarget(
            name: "P2PDiscoveryPlumtreeTests",
            dependencies: ["P2PDiscoveryPlumtree", "P2PCore", "P2PPlumtree", "P2PMux", "P2PProtocols"],
            path: "Tests/Discovery/PlumtreeDiscoveryTests"
        ),
        .target(
            name: "P2PDiscoveryBeacon",
            dependencies: [
                "P2PDiscovery",
                "P2PCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/Discovery/Beacon",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PDiscoveryBeaconTests",
            dependencies: ["P2PDiscoveryBeacon", "P2PCore"],
            path: "Tests/Discovery/BeaconTests"
        ),
        .target(
            name: "P2PDiscoveryWiFiBeacon",
            dependencies: [
                "P2PDiscoveryBeacon",
                "P2PCore",
                .product(name: "NIOUDPTransport", package: "swift-nio-udp"),
            ],
            path: "Sources/Discovery/WiFiBeacon",
            exclude: ["CONTEXT.md", "README.md"]
        ),
        .testTarget(
            name: "P2PDiscoveryWiFiBeaconTests",
            dependencies: ["P2PTestSupport", "P2PDiscoveryWiFiBeacon", "P2PDiscoveryBeacon", "P2PCore"],
            path: "Tests/Discovery/WiFiBeaconTests"
        ),
        .testTarget(
            name: "P2PDiscoveryCYCLONTests",
            dependencies: ["P2PDiscoveryCYCLON", "P2PCore"],
            path: "Tests/Discovery/CYCLONTests"
        ),

        // MARK: - NAT
        .target(
            name: "P2PNAT",
            dependencies: ["P2PCore"],
            path: "Sources/NAT/P2PNAT",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PNATTests",
            dependencies: ["P2PTestSupport", "P2PNAT"],
            path: "Tests/NAT/P2PNATTests"
        ),

        // MARK: - Protocols
        .target(
            name: "P2PProtocols",
            dependencies: ["P2PCore", "P2PMux", "P2PDiscovery"],
            path: "Sources/Protocols/P2PProtocols"
        ),
        .target(
            name: "P2PIdentify",
            dependencies: [
                "P2PProtocols",
                "P2PCore",
                "P2PMux",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Protocols/Identify",
            exclude: ["CONTEXT.md"]
        ),
        .target(
            name: "P2PPing",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/Ping",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PIdentifyTests",
            dependencies: [
                "P2PTestSupport",
                "P2PIdentify",
                "P2PCore",
                "P2PMux",
                "P2PProtocols",
                "P2PTransportQUIC",
                "P2PTransport",
                "P2PTransportSecured",
                .product(name: "QUIC", package: "swift-quic"),
            ],
            path: "Tests/Protocols/IdentifyTests"
        ),
        .testTarget(
            name: "P2PPingTests",
            dependencies: [
                "P2PTestSupport",
                "P2PPing",
                "P2PCore",
                "P2PProtocols",
                "P2PTransportQUIC",
                "P2PTransport",
                "P2PTransportSecured",
                "P2PMux",
                .product(name: "QUIC", package: "swift-quic"),
            ],
            path: "Tests/Protocols/PingTests"
        ),
        .target(
            name: "P2PGossipSub",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/GossipSub",
            exclude: ["CONTEXT.md", "README.md"]
        ),
        .testTarget(
            name: "P2PGossipSubTests",
            dependencies: ["P2PGossipSub", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/GossipSubTests"
        ),
        .target(
            name: "P2PCircuitRelay",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux", "P2PTransport"],
            path: "Sources/Protocols/CircuitRelay",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PCircuitRelayTests",
            dependencies: ["P2PCircuitRelay", "P2PTransportMemory"],
            path: "Tests/Protocols/CircuitRelayTests"
        ),
        .target(
            name: "P2PDCUtR",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/DCUtR",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PDCUtRTests",
            dependencies: ["P2PDCUtR", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/DCUtRTests"
        ),
        .target(
            name: "P2PAutoNAT",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/AutoNAT",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PAutoNATTests",
            dependencies: ["P2PAutoNAT", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/AutoNATTests"
        ),
        .target(
            name: "P2PKademlia",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/Kademlia",
            exclude: ["CONTEXT.md", "README.md"]
        ),
        .testTarget(
            name: "P2PKademliaTests",
            dependencies: ["P2PKademlia"],
            path: "Tests/Protocols/KademliaTests"
        ),
        .target(
            name: "P2PPlumtree",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/Plumtree",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PPlumtreeTests",
            dependencies: ["P2PPlumtree", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/PlumtreeTests"
        ),
        .target(
            name: "P2PRendezvous",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/Rendezvous",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PRendezvousTests",
            dependencies: ["P2PRendezvous", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/RendezvousTests"
        ),
        .target(
            name: "P2PHTTP",
            dependencies: ["P2PProtocols", "P2PCore", "P2PMux"],
            path: "Sources/Protocols/HTTP",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PHTTPTests",
            dependencies: ["P2PHTTP", "P2PCore", "P2PMux", "P2PProtocols"],
            path: "Tests/Protocols/HTTPTests"
        ),
        // MARK: - WebTransport
        .target(
            name: "P2PTransportWebTransport",
            dependencies: [
                "P2PCore",
                "P2PTransport",
                "P2PTransportSecured",
                "P2PMux",
                "P2PTransportQUIC",
                .product(name: "QUIC", package: "swift-quic"),
                .product(name: "NIOUDPTransport", package: "swift-nio-udp"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/Transport/WebTransport",
            exclude: ["CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PTransportWebTransportTests",
            dependencies: ["P2PTestSupport", "P2PTransportWebTransport", "P2PCore"],
            path: "Tests/Transport/WebTransportTests"
        ),

        // MARK: - Runtime
        .target(
            name: "P2PRuntime",
            dependencies: [
                "P2PCore",
                "P2PTransport",
                "P2PTransportSecured",
                "P2PSecurity",
                "P2PMux",
                "P2PNegotiation",
                "P2PDiscovery",
                "P2PProtocols",
            ],
            path: "Sources/Runtime/P2PRuntime"
        ),

        // MARK: - Integration
        .target(
            name: "P2P",
            dependencies: [
                // Protocol abstractions (@_exported)
                "P2PCore",
                "P2PTransport",
                "P2PTransportSecured",
                "P2PSecurity",
                "P2PMux",
                "P2PNegotiation",
                "P2PDiscovery",
                "P2PProtocols",
                "P2PRuntime",
                // Default implementations (@_exported — batteries-included)
                "P2PTransportTCP",
                "P2PSecurityNoise",
                "P2PSecurityPlaintext",
                "P2PMuxYamux",
                "P2PPing",
                "P2PGossipSub",
                "P2PKademlia",
                "P2PPlumtree",
                // Internal (non-exported)
                "P2PIdentify",
                "P2PAutoNAT",
                "P2PCircuitRelay",
                "P2PDCUtR",
                "P2PNAT",
                "P2PDiscoveryMDNS",
                "P2PDiscoverySWIM",
                "P2PDiscoveryCYCLON",
                "P2PDiscoveryPlumtree",
                "P2PDiscoveryBeacon",
                "P2PPnet",
            ],
            path: "Sources/Integration/P2P",
            exclude: ["CONTEXT.md", "Connection/CONTEXT.md"]
        ),
        .testTarget(
            name: "P2PTests",
            dependencies: [
                "P2P",
                "P2PTransportMemory",
                "P2PTransportSecured",
                "P2PSecurityPlaintext",
                "P2PMuxYamux",
                "P2PPing",
                "P2PIdentify",
                "P2PPnet",
            ],
            path: "Tests/Integration/P2PTests"
        ),

    ] + (includesInteropTests ? [
        // MARK: - Interop Tests
        .testTarget(
            name: "GoInteropTests",
            dependencies: [
                "P2P",
                "P2PIdentify",
                "P2PPing",
                "P2PCore",
                "P2PMux",
                "P2PProtocols",
                "P2PTransportQUIC",
                "P2PTransport",
                "P2PTransportTCP",
                "P2PTransportWebSocket",
                "P2PSecurityNoise",
                "P2PMuxYamux",
                "P2PGossipSub",
                "P2PKademlia",
                "P2PCircuitRelay",
                .product(name: "QUIC", package: "swift-quic"),
            ],
            path: "Tests/Interop",
            exclude: [
                "Dockerfiles",
                "README.md",
                "KNOWN_ISSUES.md",
                "docker-compose.interop.yml",
            ]
        ),

    ] : []) + (includesBenchmarks ? [
        // MARK: - Benchmarks
        .testTarget(
            name: "P2PBenchmarks",
            dependencies: [
                "P2P",
                "P2PCore",
                "P2PIdentify",
                "P2PKademlia",
                "P2PGossipSub",
                "P2PRuntime",
                "P2PTransportMemory",
                "P2PMux",
                "P2PMuxYamux",
                "P2PSecurityNoise",
                "P2PSecurityPlaintext",
                "P2PSecurityTLS",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Benchmarks/P2PBenchmarks"
        ),

    ] : []) + [
        // MARK: - Examples
        .executableTarget(
            name: "PingPongDemo",
            dependencies: [
                "P2P",
                "P2PSecurityPlaintext",
            ],
            path: "Examples/PingPongDemo"
        ),
    ]
)
