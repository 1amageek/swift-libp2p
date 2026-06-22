/// KademliaSecurityTests - Tests for Kademlia DHT security hardening fixes.
///
/// Covers:
/// - Default validator cryptographically validates /ipns/ and /pk/ (rejects forged)
/// - IPNS sequence downgrade rejected
/// - ADD_PROVIDER with provider.id != sender rejected (provider spoofing)
/// - Returned closer-peer list bounded / deduped / excludes self
/// - Iterative lookup terminates on convergence
/// - KademliaKey wire path returns a typed error instead of crashing
import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2PKademlia
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

@Suite("Kademlia Security Tests", .serialized)
struct KademliaSecurityTests {

    // MARK: - Helpers

    private func makeIdentity() -> (keyPair: KeyPair, peerID: PeerID) {
        let kp = KeyPair.generateEd25519()
        return (kp, PeerID(publicKey: kp.publicKey))
    }

    private func ipnsKey(for peerID: PeerID) -> Data {
        Data((IPNSValidator.namespace + peerID.description).utf8)
    }

    private func makeIPNSRecord(
        keyPair: KeyPair,
        value: String = "/ipfs/QmContent",
        sequence: UInt64,
        validitySeconds: TimeInterval = 3600
    ) throws -> KademliaRecord {
        let record = try IPNSRecord.create(
            value: Array(value.utf8),
            sequence: sequence,
            validity: Date().addingTimeInterval(validitySeconds),
            keyPair: keyPair
        )
        return KademliaRecord(key: ipnsKey(for: PeerID(publicKey: keyPair.publicKey)), value: Data(record.encode()))
    }

    // MARK: - Default validator: forged IPNS/pk rejection (Finding 15)

    @Test("Default KademliaService validator rejects a forged IPNS record")
    func defaultValidatorRejectsForgedIPNS() async throws {
        let validator = try #require(KademliaConfiguration.default.recordValidator)

        // A record under a valid /ipns/<peerID> key but with garbage (forged)
        // value bytes must be rejected — the default did NO signature checking.
        let (_, victimPeerID) = makeIdentity()
        let forged = KademliaRecord(
            key: ipnsKey(for: victimPeerID),
            value: Data("not-a-valid-ipns-record".utf8)
        )
        let result = try await validator.validate(record: forged, from: makeIdentity().peerID)
        #expect(result == false)
    }

    @Test("Default validator accepts a properly signed IPNS record")
    func defaultValidatorAcceptsValidIPNS() async throws {
        let validator = try #require(KademliaConfiguration.default.recordValidator)
        let (kp, _) = makeIdentity()
        let record = try makeIPNSRecord(keyPair: kp, sequence: 1)
        let result = try await validator.validate(record: record, from: makeIdentity().peerID)
        #expect(result == true)
    }

    @Test("Default validator rejects unknown namespace (defaultBehavior reject)")
    func defaultValidatorRejectsUnknownNamespace() async throws {
        let validator = try #require(KademliaConfiguration.default.recordValidator)
        let record = KademliaRecord(key: Data("arbitrary-key".utf8), value: Data("v".utf8))
        let result = try await validator.validate(record: record, from: makeIdentity().peerID)
        #expect(result == false)
    }

    @Test("Forged /pk/ record (signer != key owner) is rejected")
    func defaultValidatorRejectsForgedPK() async throws {
        let validator = try #require(KademliaConfiguration.default.recordValidator)

        // Attacker signs an envelope with their own key but stores it under the
        // victim's /pk/<peerID> key.
        let attacker = KeyPair.generateEd25519()
        let (_, victimPeerID) = makeIdentity()
        let attackerRecord = PeerRecord.make(keyPair: attacker, seq: 1, addresses: [])
        let envelope = try Envelope.seal(record: attackerRecord, with: attacker)
        let pkKey = Data(("/pk/" + victimPeerID.description).utf8)
        let forged = KademliaRecord(key: pkKey, value: try envelope.marshal())

        let result = try await validator.validate(record: forged, from: makeIdentity().peerID)
        #expect(result == false)
    }

    // MARK: - IPNS sequence downgrade (Finding 16)

    @Test("IPNS sequence downgrade is rejected by select()")
    func ipnsSequenceDowngradeRejected() async throws {
        let validator = IPNSValidator()
        let (kp, peerID) = makeIdentity()
        let key = ipnsKey(for: peerID)

        let newer = try makeIPNSRecord(keyPair: kp, value: "/ipfs/New", sequence: 5)
        let older = try makeIPNSRecord(keyPair: kp, value: "/ipfs/Old", sequence: 2)

        // select() must pick the higher-sequence record regardless of order.
        let idx1 = try await validator.select(key: key, records: [newer, older])
        #expect(idx1 == 0)  // newer is at index 0
        let idx2 = try await validator.select(key: key, records: [older, newer])
        #expect(idx2 == 1)  // newer is at index 1
    }

    @Test("Default NamespacedValidator routes IPNS select to sequence comparison")
    func defaultValidatorSelectsHigherSequence() async throws {
        let validator = try #require(KademliaConfiguration.default.recordValidator)
        let (kp, peerID) = makeIdentity()
        let key = ipnsKey(for: peerID)

        let newer = try makeIPNSRecord(keyPair: kp, value: "/ipfs/New", sequence: 9)
        let older = try makeIPNSRecord(keyPair: kp, value: "/ipfs/Old", sequence: 3)

        // The secure default must NOT fall back to "first record"; it must use
        // the IPNS sequence-aware selection.
        let idx = try await validator.select(key: key, records: [older, newer])
        #expect(idx == 1)
    }

    @Test("PUT_VALUE keeps higher-sequence IPNS record, rejects downgrade")
    func putValueRejectsIPNSDowngrade() async throws {
        let local = makeIdentity().peerID
        let service = KademliaService(localPeerID: local, configuration: .init(mode: .server))
        let (kp, peerID) = makeIdentity()
        let key = ipnsKey(for: peerID)

        let newer = try makeIPNSRecord(keyPair: kp, value: "/ipfs/New", sequence: 5)
        let older = try makeIPNSRecord(keyPair: kp, value: "/ipfs/Old", sequence: 2)

        // Helper to drive a PUT_VALUE through the inbound handler.
        func put(_ record: KademliaRecord) async throws {
            let message = KademliaMessage.putValue(record: record)
            let stream = KademliaMockStream(request: KademliaProtobuf.encode(message))
            let context = StreamContext(
                stream: stream,
                remotePeer: makeIdentity().peerID,
                remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                localPeer: local,
                localAddress: nil,
                protocolID: KademliaProtocol.protocolID
            )
            await service.handleInboundStream(context)
        }

        // Store the newer record first.
        try await put(newer)
        let afterNewer = service.recordStore.get(key)
        #expect(afterNewer?.value == newer.value)

        // Attempt to overwrite with an OLDER (lower-sequence) record — must be
        // rejected; the newer record must remain.
        try await put(older)
        let afterDowngrade = service.recordStore.get(key)
        #expect(afterDowngrade?.value == newer.value)
    }

    // MARK: - ADD_PROVIDER spoofing (Finding 17)

    @Test("ADD_PROVIDER with provider.id != sender is rejected")
    func addProviderSpoofingRejected() async throws {
        let local = makeIdentity().peerID
        let service = KademliaService(localPeerID: local, configuration: .init(mode: .server))

        let sender = makeIdentity().peerID
        let spoofedProvider = makeIdentity().peerID  // different from sender
        let key = Data("content-key".utf8)

        // Build an ADD_PROVIDER claiming a DIFFERENT provider than the sender.
        let message = KademliaMessage.addProvider(
            key: key,
            providers: [KademliaPeer(id: spoofedProvider, addresses: [])]
        )
        let stream = KademliaMockStream(request: KademliaProtobuf.encode(message))
        let context = StreamContext(
            stream: stream,
            remotePeer: sender,
            remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
            localPeer: local,
            localAddress: nil,
            protocolID: KademliaProtocol.protocolID
        )

        await service.handleInboundStream(context)

        // The spoofed provider must NOT be stored.
        let stored = service.providerStore.getProviders(for: key)
        #expect(!stored.contains { $0.peerID == spoofedProvider })
    }

    @Test("ADD_PROVIDER with provider.id == sender is accepted")
    func addProviderSelfAccepted() async throws {
        let local = makeIdentity().peerID
        let service = KademliaService(localPeerID: local, configuration: .init(mode: .server))

        let sender = makeIdentity().peerID
        let key = Data("content-key".utf8)

        let message = KademliaMessage.addProvider(
            key: key,
            providers: [KademliaPeer(id: sender, addresses: [])]
        )
        let stream = KademliaMockStream(request: KademliaProtobuf.encode(message))
        let context = StreamContext(
            stream: stream,
            remotePeer: sender,
            remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
            localPeer: local,
            localAddress: nil,
            protocolID: KademliaProtocol.protocolID
        )

        await service.handleInboundStream(context)

        let stored = service.providerStore.getProviders(for: key)
        #expect(stored.contains { $0.peerID == sender })
    }

    // MARK: - Default service rejects forged IPNS PUT_VALUE end-to-end (Finding 15)

    @Test("Default KademliaService rejects forged IPNS PUT_VALUE")
    func serviceRejectsForgedIPNSPutValue() async throws {
        let local = makeIdentity().peerID
        let service = KademliaService(localPeerID: local, configuration: .init(mode: .server))

        let (_, victimPeerID) = makeIdentity()
        let forged = KademliaRecord(
            key: ipnsKey(for: victimPeerID),
            value: Data("forged".utf8)
        )
        let message = KademliaMessage.putValue(record: forged)
        let stream = KademliaMockStream(request: KademliaProtobuf.encode(message))
        let context = StreamContext(
            stream: stream,
            remotePeer: makeIdentity().peerID,
            remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
            localPeer: local,
            localAddress: nil,
            protocolID: KademliaProtocol.protocolID
        )

        await service.handleInboundStream(context)

        // The forged record must NOT be stored locally.
        #expect(service.recordStore.get(forged.key) == nil)
    }

    // MARK: - Returned peer list bounded / deduped / excludes self (Findings 19/20)

    @Test("Lookup bounds, dedups, and excludes self from returned closer peers")
    func lookupBoundsAndDedupsPeers() async throws {
        let local = makeIdentity().peerID
        let target = makeIdentity().peerID
        let targetKey = KademliaKey(from: target)

        // The responder returns: many peers (some duplicates, self, and the
        // responder). The query must dedup, drop self/responder, and only accept
        // strictly-closer peers up to k.
        let responder = makeIdentity().peerID
        let delegate = ConfigurableQueryDelegate()

        // Build closer peers: include `local` (self) and `responder` which must
        // both be dropped, plus duplicates.
        var closer: [KademliaPeer] = []
        for _ in 0..<10 {
            closer.append(KademliaPeer(id: makeIdentity().peerID, addresses: []))
        }
        // Duplicate the first peer several times.
        let dup = closer[0]
        closer.append(contentsOf: [dup, dup, dup])
        closer.append(KademliaPeer(id: local, addresses: []))       // self
        closer.append(KademliaPeer(id: responder, addresses: []))   // responder

        delegate.findNodeResponse = closer

        let query = KademliaQuery(
            type: .findNode(targetKey),
            config: KademliaQueryConfig(alpha: 1, k: 20, maxIterations: 2),
            localPeerID: local
        )

        let result = try await query.execute(
            initialPeers: [KademliaPeer(id: responder, addresses: [])],
            delegate: delegate
        )

        guard case .nodes(let peers) = result else {
            Issue.record("Expected .nodes result")
            return
        }

        // No self, no duplicates in the returned set.
        #expect(!peers.contains { $0.id == local })
        let ids = peers.map { $0.id }
        #expect(Set(ids).count == ids.count)  // no duplicates
        #expect(peers.count <= 20)            // bounded by k
    }

    // MARK: - Convergence termination (Finding 20)

    @Test("Iterative lookup terminates on convergence (does not run all iterations)")
    func lookupTerminatesOnConvergence() async throws {
        let local = makeIdentity().peerID
        let target = makeIdentity().peerID
        let targetKey = KademliaKey(from: target)

        // A delegate that always returns the SAME far-away peer (never closer).
        // After the first round yields nothing strictly closer, the lookup must
        // converge and stop rather than running all maxIterations.
        let delegate = CallCountingDelegate()
        let farPeer = KademliaPeer(id: makeIdentity().peerID, addresses: [])
        delegate.findNodeResponse = [farPeer]

        let query = KademliaQuery(
            type: .findNode(targetKey),
            config: KademliaQueryConfig(alpha: 1, k: 20, maxIterations: 50),
            localPeerID: local
        )

        _ = try await query.execute(
            initialPeers: [KademliaPeer(id: makeIdentity().peerID, addresses: [])],
            delegate: delegate
        )

        // With convergence, far fewer than 50 round-trips occur.
        #expect(delegate.findNodeCount < 50)
    }

    // MARK: - KademliaKey wire path typed error (Finding 24)

    @Test("Wire FIND_NODE with non-32-byte key returns typed error, not crash")
    func wireInvalidKeyLengthTypedError() async throws {
        let local = makeIdentity().peerID
        let service = KademliaService(localPeerID: local, configuration: .init(mode: .server))

        // FIND_NODE with a 16-byte (invalid) key. The handler must throw a typed
        // protocol violation rather than crashing on a precondition.
        let shortKey = Data(repeating: 0x01, count: 16)
        let message = KademliaMessage.findNode(key: shortKey)
        let stream = KademliaMockStream(request: KademliaProtobuf.encode(message))
        let context = StreamContext(
            stream: stream,
            remotePeer: makeIdentity().peerID,
            remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
            localPeer: local,
            localAddress: nil,
            protocolID: KademliaProtocol.protocolID
        )

        // Must not crash. The handler catches and logs the typed error.
        await service.handleInboundStream(context)
        #expect(Bool(true))  // reaching here means no precondition crash
    }

    @Test("KademliaKey validating init rejects short input with typed error")
    func validatingKeyRejectsShortInput() {
        #expect(throws: KademliaKeyError.self) {
            _ = try KademliaKey(validating: Data(repeating: 0, count: 16))
        }
    }
}

// MARK: - Mock helpers

/// A MuxedStream that serves a single length-prefixed request and captures the
/// length-prefixed response written by the handler.
private final class KademliaMockStream: MuxedStream, Sendable {
    let id: UInt64 = 1
    let protocolID: String? = KademliaProtocol.protocolID

    private struct State {
        var requestBuffer: ByteBuffer
        var written: ByteBuffer
        var delivered: Bool = false
    }
    private let state: Mutex<State>

    init(request: Data) {
        var buf = ByteBuffer()
        Varint.encode(UInt64(request.count), into: &buf)
        buf.writeBytes(request)
        self.state = Mutex(State(requestBuffer: buf, written: ByteBuffer()))
    }

    func read() async throws -> ByteBuffer {
        state.withLock { s in
            if s.delivered { return ByteBuffer() }  // EOF on subsequent reads
            s.delivered = true
            let out = s.requestBuffer
            s.requestBuffer = ByteBuffer()
            return out
        }
    }

    func write(_ data: ByteBuffer) async throws {
        state.withLock { s in
            var d = data
            s.written.writeBuffer(&d)
        }
    }

    func closeWrite() async throws {}
    func closeRead() async throws {}
    func close() async throws {}
    func reset() async throws {}
}

/// Query delegate whose FIND_NODE response is fully configurable.
private final class ConfigurableQueryDelegate: KademliaQueryDelegate, Sendable {
    private let resp = Mutex<[KademliaPeer]>([])
    var findNodeResponse: [KademliaPeer] {
        get { resp.withLock { $0 } }
        set { resp.withLock { $0 = newValue } }
    }
    func sendFindNode(to peer: PeerID, key: KademliaKey) async throws -> [KademliaPeer] {
        resp.withLock { $0 }
    }
    func sendGetValue(to peer: PeerID, key: Data) async throws -> (record: KademliaRecord?, closerPeers: [KademliaPeer]) {
        (nil, [])
    }
    func sendGetProviders(to peer: PeerID, key: Data) async throws -> (providers: [KademliaPeer], closerPeers: [KademliaPeer]) {
        ([], [])
    }
}

/// Query delegate that counts FIND_NODE calls (to verify early termination).
private final class CallCountingDelegate: KademliaQueryDelegate, Sendable {
    private let state = Mutex<(count: Int, resp: [KademliaPeer])>((0, []))
    var findNodeResponse: [KademliaPeer] {
        get { state.withLock { $0.resp } }
        set { state.withLock { $0.resp = newValue } }
    }
    var findNodeCount: Int { state.withLock { $0.count } }
    func sendFindNode(to peer: PeerID, key: KademliaKey) async throws -> [KademliaPeer] {
        state.withLock { s in
            s.count += 1
            return s.resp
        }
    }
    func sendGetValue(to peer: PeerID, key: Data) async throws -> (record: KademliaRecord?, closerPeers: [KademliaPeer]) {
        (nil, [])
    }
    func sendGetProviders(to peer: PeerID, key: Data) async throws -> (providers: [KademliaPeer], closerPeers: [KademliaPeer]) {
        ([], [])
    }
}
