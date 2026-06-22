/// GossipSubSecurityTests - Tests for GossipSub security hardening fixes.
///
/// Covers:
/// - Peer Exchange (PX) cap + signed-peer-record verification
/// - Dedup-before-validation censorship prevention
/// - IWANT per-peer per-heartbeat response budget
/// - Per-RPC element-count caps at decode
/// - Insecure validation must be opted into explicitly
import Testing
import Foundation
import NIOCore
@testable import P2PGossipSub
@testable import P2PCore
@testable import P2PMux

@Suite("GossipSub Security Tests", .serialized)
struct GossipSubSecurityTests {

    // MARK: - Helpers

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func makeRouter(
        peerID: PeerID? = nil,
        configuration: GossipSubConfiguration = .testing
    ) -> GossipSubRouter {
        GossipSubRouter(localPeerID: peerID ?? makePeerID(), configuration: configuration)
    }

    private func makeMessage(
        topic: Topic,
        data: Data = Data("payload".utf8)
    ) -> GossipSubMessage {
        let builder = GossipSubMessage.Builder(data: data, topic: topic).autoSequenceNumber()
        do {
            return try builder.build()
        } catch {
            fatalError("Failed to build test message: \(error)")
        }
    }

    /// Builds a valid signed peer-record envelope for `keyPair`.
    private func makeSignedPeerRecord(for keyPair: KeyPair) throws -> Data {
        let record = PeerRecord.make(keyPair: keyPair, seq: 1, addresses: [])
        let envelope = try Envelope.seal(record: record, with: keyPair)
        return try envelope.marshal()
    }

    /// Sends a PRUNE carrying PX entries and returns the events the router
    /// emitted. The router is shut down first so the event stream is finite and
    /// can be drained deterministically (no dangling consumer task).
    private func collectPXEvents(
        router: GossipSubRouter,
        topic: Topic,
        peers: [ControlMessage.Prune.PeerInfo],
        from sender: PeerID
    ) async throws -> [GossipSubEvent] {
        // Access the stream FIRST so the EventChannel continuation exists and
        // buffers events emitted during handleRPC (yields before any stream
        // access are dropped).
        let stream = router.events

        var control = ControlMessageBatch()
        control.prunes.append(ControlMessage.Prune(topic: topic, peers: peers))
        _ = await router.handleRPC(GossipSubRPC(control: control), from: sender)

        // Finish the stream so iteration terminates, then drain buffered events.
        try await router.shutdown()
        var collected: [GossipSubEvent] = []
        for await event in stream {
            collected.append(event)
        }
        return collected
    }

    // MARK: - Peer Exchange (Findings 1 & 2)

    @Test("Signed peer record round-trips and verifies")
    func signedPeerRecordRoundTrip() throws {
        let kp = KeyPair.generateEd25519()
        let bytes = try makeSignedPeerRecord(for: kp)
        let envelope = try Envelope.unmarshal(bytes)
        // Verify signature, then unmarshal from a zero-based payload copy.
        // (Envelope.record(as:) would crash here due to a Core slice-indexing
        // bug in PeerRecord.unmarshal; see GossipSubRouter.handlePeerExchange.)
        #expect(try envelope.verify(as: PeerRecord.self))
        let record = try PeerRecord.unmarshal(Data(envelope.payload))
        #expect(record.peerID == kp.peerID)
        #expect(envelope.peerID == kp.peerID)
    }

    @Test("PX with valid signed records is accepted, capped at prunePeers")
    func pxAcceptsVerifiedRecordsCapped() async throws {
        var config = GossipSubConfiguration.testing
        config.enablePeerExchange = true
        config.prunePeers = 2
        config.acceptPXThreshold = -1_000_000  // accept regardless of sender score

        let router = makeRouter(configuration: config)
        let topic = Topic("px-topic")
        let sender = makePeerID()

        // Build 4 valid PX entries; only `prunePeers` (2) should be accepted.
        var peerInfos: [ControlMessage.Prune.PeerInfo] = []
        for _ in 0..<4 {
            let kp = KeyPair.generateEd25519()
            let recordBytes = try makeSignedPeerRecord(for: kp)
            peerInfos.append(.init(peerID: kp.peerID, signedPeerRecord: recordBytes))
        }

        let events = try await collectPXEvents(router: router, topic: topic, peers: peerInfos, from: sender)
        let connected: [PeerID] = events.compactMap {
            if case .peerExchangeConnect(let peers) = $0 { return peers }
            return nil
        }.first ?? []
        #expect(connected.count == 2)
    }

    @Test("PX entries without signed records are rejected (no dial)")
    func pxRejectsUnsignedEntries() async throws {
        var config = GossipSubConfiguration.testing
        config.enablePeerExchange = true
        config.prunePeers = 4
        config.acceptPXThreshold = -1_000_000

        let router = makeRouter(configuration: config)
        let topic = Topic("px-topic")
        let sender = makePeerID()

        // PX entries WITHOUT a signed record must be dropped.
        let infos = (0..<3).map { _ in
            ControlMessage.Prune.PeerInfo(peerID: makePeerID(), signedPeerRecord: nil)
        }

        let events = try await collectPXEvents(router: router, topic: topic, peers: infos, from: sender)
        let sawConnect = events.contains { if case .peerExchangeConnect = $0 { return true }; return false }
        let sawReject = events.contains {
            if case .peerExchangeRejected(_, _, let reason) = $0,
               case .unverifiedPeerRecords = reason { return true }
            return false
        }
        #expect(!sawConnect)
        #expect(sawReject)
    }

    @Test("PX entry with mismatched PeerID is rejected")
    func pxRejectsMismatchedPeerID() async throws {
        var config = GossipSubConfiguration.testing
        config.enablePeerExchange = true
        config.prunePeers = 4
        config.acceptPXThreshold = -1_000_000

        let router = makeRouter(configuration: config)
        let topic = Topic("px-topic")
        let sender = makePeerID()

        // Sign a record with one key but claim a DIFFERENT PeerID.
        let realKP = KeyPair.generateEd25519()
        let recordBytes = try makeSignedPeerRecord(for: realKP)
        let attackerClaimedID = makePeerID()  // not the signer

        let events = try await collectPXEvents(
            router: router,
            topic: topic,
            peers: [.init(peerID: attackerClaimedID, signedPeerRecord: recordBytes)],
            from: sender
        )
        let sawConnect = events.contains { if case .peerExchangeConnect = $0 { return true }; return false }
        #expect(!sawConnect)
    }

    @Test("PX is ignored entirely when peer exchange disabled")
    func pxIgnoredWhenDisabled() async throws {
        var config = GossipSubConfiguration.testing
        config.enablePeerExchange = false  // disabled
        config.prunePeers = 4
        config.acceptPXThreshold = -1_000_000

        let router = makeRouter(configuration: config)
        let topic = Topic("px-topic")
        let sender = makePeerID()
        let kp = KeyPair.generateEd25519()
        let recordBytes = try makeSignedPeerRecord(for: kp)

        let events = try await collectPXEvents(
            router: router,
            topic: topic,
            peers: [.init(peerID: kp.peerID, signedPeerRecord: recordBytes)],
            from: sender
        )
        let sawConnect = events.contains { if case .peerExchangeConnect = $0 { return true }; return false }
        let sawDisabled = events.contains {
            if case .peerExchangeRejected(_, _, let reason) = $0,
               case .peerExchangeDisabled = reason { return true }
            return false
        }
        #expect(!sawConnect)
        #expect(sawDisabled)
    }

    // MARK: - Dedup-before-validation (Finding 3)

    @Test("Forged-ID message does not suppress the real message (no censorship)")
    func dedupAfterValidationPreventsCensorship() async throws {
        // Validation rejects messages whose data does not start with "good".
        struct PrefixValidator: MessageValidator {
            func validate(message: GossipSubMessage, from peer: PeerID) async -> GossipSubMessage.ValidationResult {
                message.data.starts(with: Data("good".utf8)) ? .accept : .reject
            }
        }

        let router = makeRouter()
        let topic = Topic("censor-topic")
        _ = try router.subscribe(to: topic)
        router.registerValidator(PrefixValidator(), for: topic)

        let attacker = makePeerID()
        let honest = makePeerID()

        // Attacker sends a message that FAILS validation but shares an ID with
        // a legitimate message. We forge a shared ID by using a custom message
        // built from identical source/seqno.
        let sharedID = MessageID(bytes: Data("shared-forged-id".utf8))
        let forged = GossipSubMessage(
            id: sharedID,
            source: nil,
            data: Data("evil".utf8),  // fails the prefix validator
            sequenceNumber: Data(count: 8),
            topic: topic
        )
        let legit = GossipSubMessage(
            id: sharedID,
            source: nil,
            data: Data("good-news".utf8),  // passes the prefix validator
            sequenceNumber: Data(count: 8),
            topic: topic
        )

        // Attacker's forged message arrives first and is rejected.
        _ = await router.handleRPC(GossipSubRPC(messages: [forged]), from: attacker)
        #expect(!router.seenCache.contains(sharedID))  // not poisoned
        #expect(!router.messageCache.contains(sharedID))

        // The legitimate message with the same ID still gets delivered/cached.
        _ = await router.handleRPC(GossipSubRPC(messages: [legit]), from: honest)
        #expect(router.seenCache.contains(sharedID))
        #expect(router.messageCache.contains(sharedID))
    }

    // MARK: - IWANT response budget (Finding 5)

    @Test("IWANT response is bounded by per-peer per-heartbeat budget")
    func iwantBudgetEnforced() async throws {
        var config = GossipSubConfiguration.testing
        config.maxIWantResponseMessages = 2  // serve at most 2 per heartbeat
        config.maxIWantResponseBytes = 1024 * 1024

        let router = makeRouter(configuration: config)
        let topic = Topic("iwant-topic")
        _ = try router.subscribe(to: topic)

        // Populate the message cache with 5 messages and collect their IDs.
        var ids: [MessageID] = []
        for i in 0..<5 {
            let msg = makeMessage(topic: topic, data: Data("m\(i)".utf8))
            router.messageCache.put(msg)
            ids.append(msg.id)
        }

        let requester = makePeerID()
        var control = ControlMessageBatch()
        control.iwants.append(ControlMessage.IWant(messageIDs: ids))

        let result = await router.handleRPC(GossipSubRPC(control: control), from: requester)
        let served = result.response?.messages.count ?? 0
        // Budget is 2, so at most 2 served despite requesting 5.
        #expect(served == 2)

        // A second IWANT in the SAME heartbeat window serves nothing more.
        let result2 = await router.handleRPC(GossipSubRPC(control: control), from: requester)
        #expect((result2.response?.messages.count ?? 0) == 0)

        // After resetting the budget (heartbeat boundary), serving resumes.
        router.resetIWantBudget()
        let result3 = await router.handleRPC(GossipSubRPC(control: control), from: requester)
        #expect((result3.response?.messages.count ?? 0) == 2)
    }

    // MARK: - Per-RPC element caps (Finding 6)

    @Test("Decode caps repeated published messages")
    func decodeCapsMessages() throws {
        let topic = Topic("cap-topic")
        var rpc = GossipSubRPC()
        for i in 0..<50 {
            rpc.messages.append(makeMessage(topic: topic, data: Data("d\(i)".utf8)))
        }
        let encoded = GossipSubProtobuf.encode(rpc)

        let limits = GossipSubProtobuf.DecodingLimits(maxMessages: 10)
        let decoded = try GossipSubProtobuf.decode(encoded, limits: limits)
        #expect(decoded.messages.count == 10)
    }

    @Test("Decode caps repeated control elements")
    func decodeCapsControl() throws {
        var control = ControlMessageBatch()
        for i in 0..<40 {
            control.ihaves.append(ControlMessage.IHave(topic: Topic("t\(i)"), messageIDs: []))
            control.iwants.append(ControlMessage.IWant(messageIDs: []))
        }
        let encoded = GossipSubProtobuf.encode(GossipSubRPC(control: control))

        let limits = GossipSubProtobuf.DecodingLimits(maxIHave: 5, maxIWant: 7)
        let decoded = try GossipSubProtobuf.decode(encoded, limits: limits)
        #expect(decoded.control?.ihaves.count == 5)
        #expect(decoded.control?.iwants.count == 7)
    }

    // MARK: - Insecure validation opt-in (Finding 13)

    @Test("Default config rejects .none validation mode")
    func noneValidationRequiresOptIn() {
        var config = GossipSubConfiguration()
        config.validationMode = GossipSubConfiguration.ValidationMode.none
        #expect(throws: GossipSubConfiguration.ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("Disabling signature validation requires explicit opt-in")
    func disabledSignaturesRequiresOptIn() {
        var config = GossipSubConfiguration()
        config.validateSignatures = false
        config.signMessages = false
        // Not opted in → validate() must throw.
        #expect(throws: GossipSubConfiguration.ConfigurationError.self) {
            try config.validate()
        }
        // Opted in → validate() must pass.
        config.allowInsecureValidation = true
        #expect(throws: Never.self) {
            try config.validate()
        }
    }

    // MARK: - Inbound GRAFT bounded by D_high (Finding 11)

    @Test("Inbound GRAFT is PRUNEd once mesh reaches D_high")
    func graftBoundedByDHigh() async throws {
        var config = GossipSubConfiguration.testing
        config.meshDegreeHigh = 3
        let router = makeRouter(configuration: config)
        let topic = Topic("graft-topic")
        _ = try router.subscribe(to: topic)

        // Fill the mesh to D_high.
        for _ in 0..<3 {
            router.meshState.addToMesh(makePeerID(), for: topic)
        }
        #expect(router.meshState.meshPeerCount(for: topic) == 3)

        // A new GRAFT must be rejected with a PRUNE (mesh at D_high), and the
        // grafter must NOT be added to the mesh.
        let grafter = makePeerID()
        var control = ControlMessageBatch()
        control.grafts.append(ControlMessage.Graft(topic: topic))
        let result = await router.handleRPC(GossipSubRPC(control: control), from: grafter)

        let prunes = result.response?.control?.prunes ?? []
        #expect(prunes.count == 1)
        #expect(!router.meshState.isInMesh(grafter, for: topic))
    }
}
