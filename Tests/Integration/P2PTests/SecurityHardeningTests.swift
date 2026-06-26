/// SecurityHardeningTests - Regression tests for the security/concurrency
/// hardening of the core/runtime/integration layers.
///
/// Covers:
/// - Default Node ships a real resource manager enforcing connection/stream limits
/// - Production validation errors on a disabled resource manager and on plaintext
/// - Per-protocol stream limit enforced at a swarm call site
/// - closePeer / handleConnectionClosed release counters exactly once (no drift)
/// - DialBackoff throttles a redial to a dead peer
/// - PeerID rejects an unsupported key type at derivation
/// - A configured PSK is applied in the dial pipeline and fails closed otherwise

import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2P
@testable import P2PCore
@testable import P2PRuntime
@testable import P2PTransport
@testable import P2PTransportSecured
@testable import P2PTransportMemory
@testable import P2PSecurity
@testable import P2PSecurityNoise
@testable import P2PSecurityPlaintext
@testable import P2PMux
@testable import P2PMuxYamux
@testable import P2PPnet

@Suite("Security Hardening", .serialized)
struct SecurityHardeningTests {

    // MARK: - Helpers

    private func makeNode(
        name: String,
        hub: MemoryHub,
        keyPair: KeyPair = .generateEd25519(),
        listenAddress: Multiaddr? = nil,
        resourceManager: any ResourceManager = DefaultResourceManager(configuration: .default),
        privateNetwork: PnetConfiguration? = nil,
        useNoise: Bool = false
    ) -> Node {
        var listenAddresses: [Multiaddr] = []
        if let addr = listenAddress { listenAddresses.append(addr) }
        // PSK tests use Noise: pnet has no PSK authentication of its own, so a
        // mismatched PSK is only detectable when the subsequent (authenticated)
        // security handshake fails — Noise's AEAD MAC fails deterministically,
        // whereas plaintext would silently exchange garbage and never converge.
        let security: [any SecurityUpgrader] = useNoise ? [NoiseUpgrader()] : [PlaintextUpgrader()]
        let config = NodeConfiguration(
            keyPair: keyPair,
            listenAddresses: listenAddresses,
            transports: [MemoryTransport(hub: hub)],
            security: security,
            muxers: [YamuxMuxer()],
            pool: PoolConfiguration(
                limits: .development,
                reconnectionPolicy: .disabled,
                idleTimeout: .seconds(300)
            ),
            healthCheck: nil,
            resourceManager: resourceManager,
            privateNetwork: privateNetwork
        )
        return Node(configuration: config)
    }

    /// Runs `operation` with a hard deadline so a failed-to-fail-closed path
    /// surfaces as a test failure rather than hanging the whole suite.
    private func withDeadline<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw DeadlineExceeded()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    struct DeadlineExceeded: Error {}

    private func psk(_ byte: UInt8) throws -> PnetConfiguration {
        try PnetConfiguration(psk: [UInt8](repeating: byte, count: 32))
    }

    // MARK: - Finding #1: default Node has a real, enforcing resource manager

    @Test("Default Node ships an enforcing resource manager (not unlimited)", .timeLimit(.minutes(1)))
    func defaultNodeHasEnforcingResourceManager() async throws {
        let config = NodeConfiguration(keyPair: .generateEd25519())
        // Not a NullResourceManager (the explicit opt-out): a real enforcing one.
        #expect(config.resourceManager is DefaultResourceManager)
        #expect(!(config.resourceManager is NullResourceManager))

        // And it actually enforces a per-peer connection limit.
        let rm = DefaultResourceManager(
            configuration: ResourceLimitsConfiguration(
                peer: ScopeLimits(maxInboundConnections: 1)
            )
        )
        let peer = KeyPair.generateEd25519().peerID
        try rm.reserveInboundConnection(from: peer)
        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: peer)
        }
    }

    @Test("NullResourceManager is the explicit, visible opt-out", .timeLimit(.minutes(1)))
    func nullResourceManagerIsExplicitOptOut() async throws {
        let config = NodeConfiguration(
            keyPair: .generateEd25519(),
            resourceManager: NullResourceManager()
        )
        #expect(config.resourceManager is NullResourceManager)
    }

    // MARK: - Finding #2 / #13: production validation errors

    @Test("Production validation errors on disabled resource manager", .timeLimit(.minutes(1)))
    func productionValidationErrorsOnDisabledResourceManager() async throws {
        let config = NodeConfiguration(
            keyPair: .generateEd25519(),
            resourceManager: NullResourceManager()
        )
        let report = config.validationReport(for: .production)
        #expect(report.errors.contains(.disabledResourceManagerInProduction))
    }

    @Test("Production validation errors on plaintext security", .timeLimit(.minutes(1)))
    func productionValidationErrorsOnPlaintext() async throws {
        let hub = MemoryHub()
        let report = NodeConfiguration.validateProfileInputs(
            profile: .production,
            connectionProviderAuditMode: .transparentComposition,
            connectionProviders: [],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            healthCheck: .production,
            resourceManager: DefaultResourceManager()
        )
        #expect(report.errors.contains(.plaintextSecurityInProduction))
    }

    @Test("start(validating:) rejects plaintext under production profile", .timeLimit(.minutes(1)))
    func startValidatingRejectsPlaintextInProduction() async throws {
        // A plain configuration (no construction-time profile guard) that uses
        // plaintext must be rejected when validated against the production
        // profile at start time.
        let hub = MemoryHub()
        let node = makeNode(name: "plaintext", hub: hub)
        await #expect(throws: NodeStartValidationError.self) {
            try await node.start(validating: .production, behavior: .warn)
        }
    }

    @Test("Production profile config carries its profile and starts validated", .timeLimit(.minutes(1)))
    func productionProfileConfigStartsValidated() async throws {
        // A production-profile config (Noise + default RM) passes the
        // construction guard, carries operationalProfile, and start() — which
        // re-validates against that stored profile — succeeds without throwing.
        let hub = MemoryHub()
        let config = try NodeConfiguration(
            profile: .production,
            auditPolicy: .permissive,
            transports: [MemoryTransport(hub: hub)],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        )
        #expect(config.operationalProfile == .production)
        #expect(config.resourceManager is DefaultResourceManager)
        let node = Node(configuration: config)
        try await node.start()
        try await node.shutdown()
        hub.reset()
    }

    // MARK: - Finding #3: per-protocol stream limit enforced at a swarm call site

    @Test("Per-protocol outbound stream limit enforced at newStream", .timeLimit(.minutes(1)))
    func perProtocolStreamLimitEnforcedAtNewStream() async throws {
        let hub = MemoryHub()
        let protocolID = "/limited/1.0.0"
        // Allow only one concurrent stream for this protocol.
        let clientRM = DefaultResourceManager(
            configuration: ResourceLimitsConfiguration(
                system: .unlimited,
                peer: .unlimited,
                protocolLimits: .unlimited,
                protocolOverrides: [protocolID: ScopeLimits(maxOutboundStreams: 1)]
            )
        )
        let serverAddr = Multiaddr.memory(id: "proto-limit-server")
        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub, resourceManager: clientRM)

        await server.handle(protocolID) { ctx in
            // Keep the stream open by reading until closed.
            while (try? await ctx.stream.read()) != nil {}
        }

        try await server.start()
        try await client.start()
        defer {
            Task { try? await client.shutdown(); try? await server.shutdown(); hub.reset() }
        }

        let peer = try await client.connect(to: serverAddr)

        // First stream succeeds and is retained (counts against the limit).
        let s1 = try await client.newStream(to: peer, protocol: protocolID)
        _ = s1

        // Second stream must be rejected by the per-protocol limit.
        await #expect(throws: NodeError.self) {
            _ = try await client.newStream(to: peer, protocol: protocolID)
        }
    }

    // MARK: - Finding #5: exactly-once resource release (no drift)

    @Test("closePeer then connection-closed releases counters exactly once", .timeLimit(.minutes(1)))
    func exactlyOnceReleaseOnClose() async throws {
        let hub = MemoryHub()
        let clientRM = DefaultResourceManager(configuration: .default)
        let serverAddr = Multiaddr.memory(id: "exactly-once-server")
        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr)
        let client = makeNode(name: "client", hub: hub, resourceManager: clientRM)

        try await server.start()
        try await client.start()

        let peer = try await client.connect(to: serverAddr)
        // One outbound connection reserved.
        #expect(clientRM.snapshot().system.outboundConnections == 1)

        // closePeer + the connection's inbound-stream loop ending both race to
        // release. With exactly-once semantics the counter returns to 0, never
        // underflows (an underflow would trip the assertion in decrement()).
        await client.disconnect(from: peer)

        // Give the connection-closed path time to run.
        try await Task.sleep(for: .milliseconds(200))

        let snap = clientRM.snapshot()
        #expect(snap.system.outboundConnections == 0)
        #expect(snap.peers[peer] == nil)

        try await client.shutdown()
        try await server.shutdown()
        hub.reset()
    }

    // MARK: - Finding #6: DialBackoff throttles a dead-peer redial

    @Test("DialBackoff suppresses an immediate redial to a failed peer", .timeLimit(.minutes(1)))
    func dialBackoffThrottlesDeadPeerRedial() async throws {
        let hub = MemoryHub()
        let client = makeNode(name: "client", hub: hub)
        try await client.start()
        defer { Task { try? await client.shutdown(); hub.reset() } }

        // Address embeds a peer ID but points at a non-existent listener.
        let deadKey = KeyPair.generateEd25519()
        let deadAddr = try Multiaddr.memory(id: "dead-peer").appending(.p2p(deadKey.peerID))

        // First dial fails (no listener) and records a failure.
        await #expect(throws: (any Error).self) {
            _ = try await client.connect(to: deadAddr)
        }

        // Immediate redial is suppressed by backoff with a typed error.
        await #expect(throws: NodeError.self) {
            do {
                _ = try await client.connect(to: deadAddr)
            } catch let error as NodeError {
                if case .dialBackedOff = error { throw error }
                // Any other NodeError also satisfies the throws expectation, but
                // we specifically want backoff here.
                Issue.record("Expected dialBackedOff, got \(error)")
                throw error
            }
        }
    }

    // MARK: - Finding #9: BlocklistGater uses structured component matching

    @Test("BlocklistGater matches structured components, not substrings", .timeLimit(.minutes(1)))
    func blocklistGaterStructuredMatching() throws {
        let gater = BlocklistGater()
        gater.block(address: "10.0.0.1")

        let blocked = try Multiaddr("/ip4/10.0.0.1/tcp/4001")
        let lookalike = try Multiaddr("/ip4/110.0.0.1/tcp/4001")  // substring of "10.0.0.1"? no — but "10.0.0.1" is a substring of "110.0.0.1"

        // Exact IP component is blocked.
        #expect(!gater.interceptDial(peer: nil, address: blocked))
        #expect(!gater.interceptAccept(address: blocked))
        // A different IP that merely CONTAINS the blocked string is NOT blocked
        // (the old substring matcher would have over-blocked this).
        #expect(gater.interceptDial(peer: nil, address: lookalike))
        #expect(gater.interceptAccept(address: lookalike))
    }

    @Test("BlocklistGater blocks by DNS host component", .timeLimit(.minutes(1)))
    func blocklistGaterBlocksDNSHost() throws {
        let gater = BlocklistGater()
        gater.block(address: "evil.example.com")
        let blocked = try Multiaddr("/dns4/evil.example.com/tcp/443")
        let allowed = try Multiaddr("/dns4/good.example.com/tcp/443")
        #expect(!gater.interceptDial(peer: nil, address: blocked))
        #expect(gater.interceptDial(peer: nil, address: allowed))
    }

    // MARK: - Finding #10: PeerID rejects unsupported key type at derivation

    @Test("Unsupported key types are rejected at PublicKey derivation", .timeLimit(.minutes(1)))
    func unsupportedKeyTypeRejectedAtDerivation() throws {
        // secp256k1 / RSA are unsupported by design: construction fails fast,
        // so a PeerID can never be derived from an unverifiable key.
        #expect(throws: PublicKeyError.self) {
            _ = try PublicKey(keyType: .secp256k1, rawBytes: Data(repeating: 0x02, count: 33))
        }
        #expect(throws: PublicKeyError.self) {
            _ = try PublicKey(keyType: .rsa, rawBytes: Data(repeating: 0x01, count: 64))
        }
    }

    // MARK: - Finding #12: PSK applied in the dial pipeline; fails closed

    @Test("Configured PSK is applied so matching nodes connect", .timeLimit(.minutes(1)))
    func pskAppliedMatchingNodesConnect() async throws {
        let hub = MemoryHub()
        let psk = try psk(0xAB)
        let serverAddr = Multiaddr.memory(id: "pnet-match-server")
        let server = makeNode(name: "server", hub: hub, listenAddress: serverAddr, privateNetwork: psk, useNoise: true)
        let client = makeNode(name: "client", hub: hub, privateNetwork: psk, useNoise: true)

        try await server.start()
        try await client.start()
        defer { Task { try? await client.shutdown(); try? await server.shutdown(); hub.reset() } }

        let peer = try await withDeadline(.seconds(10)) {
            try await client.connect(to: serverAddr)
        }
        let connection = await client.connection(to: peer)
        #expect(connection != nil)
    }

    @Test("Upgrade fails closed when the protector throws (no unprotected fallback)", .timeLimit(.minutes(1)))
    func upgradeFailsClosedWhenProtectorThrows() async throws {
        // When a protector is configured it runs before security and MUST fail
        // closed: if protect() throws, the upgrade throws and the raw connection
        // is closed — there is no fallback to an unprotected upgrade. This is the
        // deterministic wiring-point assertion for finding #12 (the live
        // mismatched-PSK case depends on transport-level dial timeouts, which are
        // out of scope here).
        let upgrader = NegotiatingUpgrader(
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()],
            protector: ThrowingProtector()
        )
        let raw = RecordingRawConnection()

        await #expect(throws: ThrowingProtector.ProtectFailed.self) {
            _ = try await upgrader.upgrade(
                raw,
                localKeyPair: .generateEd25519(),
                role: .initiator,
                expectedPeer: nil
            )
        }
        // Fail-closed: no security negotiation bytes were ever written, i.e. the
        // pipeline did not proceed to an unprotected upgrade.
        #expect(raw.writeCount == 0)
    }

    @Test("PSK with a secured transport fails closed", .timeLimit(.minutes(1)))
    func pskWithSecuredTransportFailsClosed() async throws {
        // A PSK protector cannot be inserted before a secured transport's own
        // security; composing them must fail closed rather than silently dialing
        // unprotected.
        let providers = ConnectionProviders.compose(
            transports: [StubSecuredTransport()],
            security: [],
            muxers: [],
            protector: PnetProtector(configuration: try psk(0x33))
        )
        let provider = try #require(providers.first)
        await #expect(throws: ConnectionProviderError.self) {
            _ = try await provider.dial(
                Multiaddr.memory(id: "secured"),
                identity: LocalIdentity(keyPair: .generateEd25519())
            )
        }
    }
}

// MARK: - Stubs for the protector fail-closed test

/// A protector that always fails — used to prove the upgrade fails closed.
private struct ThrowingProtector: ConnectionProtector {
    struct ProtectFailed: Error {}
    func protect(_ raw: any RawConnection) async throws -> any RawConnection {
        throw ProtectFailed()
    }
}

/// A raw connection that records whether any bytes were written, so the test can
/// assert the pipeline never proceeded to (unprotected) security negotiation.
private final class RecordingRawConnection: RawConnection, Sendable {
    private let writes = Mutex(0)
    var writeCount: Int { writes.withLock { $0 } }

    var localAddress: Multiaddr? { nil }
    var remoteAddress: Multiaddr { Multiaddr.memory(id: "recording") }

    func read() async throws -> ByteBuffer { ByteBuffer() }
    func write(_ data: ByteBuffer) async throws { writes.withLock { $0 += 1 } }
    func close() async throws {}
}

// MARK: - Stub secured transport for the PSK fail-closed test

// The UnsupportedProtectorConnectionProvider rejects dial/listen before reaching
// the transport, so these method bodies are never exercised — they exist only to
// satisfy the SecuredTransport protocol.
private struct StubSecuredTransport: SecuredTransport {
    var protocols: [[String]] { [["memory"]] }
    var pathKind: TransportPathKind { .ip }
    func canDial(_ address: Multiaddr) -> Bool { true }
    func canListen(_ address: Multiaddr) -> Bool { true }
    func dial(_ address: Multiaddr) async throws -> any RawConnection {
        throw TransportError.unsupportedOperation("stub")
    }
    func listen(_ address: Multiaddr) async throws -> any Listener {
        throw TransportError.unsupportedOperation("stub")
    }
    func dialSecured(_ address: Multiaddr, localKeyPair: KeyPair) async throws -> any MuxedConnection {
        throw TransportError.unsupportedOperation("stub")
    }
    func listenSecured(_ address: Multiaddr, localKeyPair: KeyPair) async throws -> any SecuredListener {
        throw TransportError.unsupportedOperation("stub")
    }
}
