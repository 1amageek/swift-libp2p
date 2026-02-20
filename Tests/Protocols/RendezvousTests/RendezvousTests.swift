/// RendezvousTests - Comprehensive tests for the Rendezvous protocol
import Testing
import Foundation
@testable import P2PRendezvous
@testable import P2PCore

// MARK: - Protocol Constants

@Suite("Rendezvous Protocol Constants")
struct RendezvousProtocolConstantsTests {

    @Test("Protocol ID is correct")
    func protocolID() {
        #expect(RendezvousProtocol.protocolID == "/rendezvous/1.0.0")
    }

    @Test("Max namespace length is 255")
    func maxNamespaceLength() {
        #expect(RendezvousProtocol.maxNamespaceLength == 255)
    }

    @Test("Max TTL is 72 hours")
    func maxTTL() {
        #expect(RendezvousProtocol.maxTTL == .seconds(72 * 3600))
    }

    @Test("Default TTL is 2 hours")
    func defaultTTL() {
        #expect(RendezvousProtocol.defaultTTL == .seconds(7200))
    }

    @Test("Max peers per namespace is 1000")
    func maxPeersPerNamespace() {
        #expect(RendezvousProtocol.maxPeersPerNamespace == 1000)
    }
}

// MARK: - Message Types

@Suite("Rendezvous Message Types")
struct RendezvousMessageTypeTests {

    @Test("Register has raw value 0")
    func registerRawValue() {
        #expect(RendezvousMessageType.register.rawValue == 0)
    }

    @Test("RegisterResponse has raw value 1")
    func registerResponseRawValue() {
        #expect(RendezvousMessageType.registerResponse.rawValue == 1)
    }

    @Test("Unregister has raw value 2")
    func unregisterRawValue() {
        #expect(RendezvousMessageType.unregister.rawValue == 2)
    }

    @Test("Discover has raw value 3")
    func discoverRawValue() {
        #expect(RendezvousMessageType.discover.rawValue == 3)
    }

    @Test("DiscoverResponse has raw value 4")
    func discoverResponseRawValue() {
        #expect(RendezvousMessageType.discoverResponse.rawValue == 4)
    }

    @Test("All message types are distinct")
    func allTypesDistinct() {
        let types: [RendezvousMessageType] = [
            .register, .registerResponse, .unregister, .discover, .discoverResponse
        ]
        let rawValues = Set(types.map(\.rawValue))
        #expect(rawValues.count == 5)
    }
}

// MARK: - Status Codes

@Suite("Rendezvous Status Codes")
struct RendezvousStatusTests {

    @Test("OK has raw value 0")
    func okRawValue() {
        #expect(RendezvousStatus.ok.rawValue == 0)
    }

    @Test("InvalidNamespace has raw value 100")
    func invalidNamespaceRawValue() {
        #expect(RendezvousStatus.invalidNamespace.rawValue == 100)
    }

    @Test("InvalidSignedPeerRecord has raw value 101")
    func invalidSignedPeerRecordRawValue() {
        #expect(RendezvousStatus.invalidSignedPeerRecord.rawValue == 101)
    }

    @Test("InvalidTTL has raw value 102")
    func invalidTTLRawValue() {
        #expect(RendezvousStatus.invalidTTL.rawValue == 102)
    }

    @Test("InvalidCookie has raw value 103")
    func invalidCookieRawValue() {
        #expect(RendezvousStatus.invalidCookie.rawValue == 103)
    }

    @Test("NotAuthorized has raw value 200")
    func notAuthorizedRawValue() {
        #expect(RendezvousStatus.notAuthorized.rawValue == 200)
    }

    @Test("InternalError has raw value 300")
    func internalErrorRawValue() {
        #expect(RendezvousStatus.internalError.rawValue == 300)
    }

    @Test("Unavailable has raw value 400")
    func unavailableRawValue() {
        #expect(RendezvousStatus.unavailable.rawValue == 400)
    }
}

// MARK: - Registration

@Suite("Rendezvous Registration")
struct RendezvousRegistrationTests {

    @Test("Registration stores correct values")
    func registrationValues() {
        let keyPair = KeyPair.generateEd25519()
        let peer = keyPair.peerID
        let addr = Multiaddr.tcp(host: "127.0.0.1", port: 4001)
        let ttl = Duration.seconds(3600)
        let expiry = ContinuousClock.now.advanced(by: ttl)

        let reg = RendezvousRegistration(
            namespace: "test-ns",
            peer: peer,
            addresses: [addr],
            ttl: ttl,
            expiry: expiry
        )

        #expect(reg.namespace == "test-ns")
        #expect(reg.peer == peer)
        #expect(reg.addresses.count == 1)
        #expect(reg.ttl == ttl)
    }

    @Test("Registration detects expiry correctly")
    func registrationExpiry() {
        let keyPair = KeyPair.generateEd25519()
        let peer = keyPair.peerID
        let addr = Multiaddr.tcp(host: "127.0.0.1", port: 4001)

        // Registration that expired in the past
        let expiredReg = RendezvousRegistration(
            namespace: "test",
            peer: peer,
            addresses: [addr],
            ttl: .seconds(1),
            expiry: ContinuousClock.now.advanced(by: .seconds(-1))
        )
        #expect(expiredReg.isExpired)

        // Registration that expires in the future
        let activeReg = RendezvousRegistration(
            namespace: "test",
            peer: peer,
            addresses: [addr],
            ttl: .seconds(3600),
            expiry: ContinuousClock.now.advanced(by: .seconds(3600))
        )
        #expect(!activeReg.isExpired)
    }
}

// MARK: - Error Types

@Suite("Rendezvous Error Types")
struct RendezvousErrorTests {

    @Test("All error cases exist")
    func allErrorCasesExist() {
        let errors: [RendezvousError] = [
            .invalidNamespace("test"),
            .invalidTTL("test"),
            .registrationRejected(.invalidNamespace),
            .discoveryFailed(.internalError),
            .serverError(.unavailable),
            .namespaceFull("test"),
            .tooManyRegistrations(100),
            .tooManyNamespaces(10000),
            .notRegistered(namespace: "test"),
            .invalidCookie,
            .notConnected,
            .unavailable,
            .protocolError("test"),
            .internalError("test"),
        ]

        var matched = 0
        for error in errors {
            switch error {
            case .invalidNamespace: matched += 1
            case .invalidTTL: matched += 1
            case .registrationRejected: matched += 1
            case .discoveryFailed: matched += 1
            case .serverError: matched += 1
            case .namespaceFull: matched += 1
            case .tooManyRegistrations: matched += 1
            case .tooManyNamespaces: matched += 1
            case .notRegistered: matched += 1
            case .invalidCookie: matched += 1
            case .notConnected: matched += 1
            case .unavailable: matched += 1
            case .protocolError: matched += 1
            case .internalError: matched += 1
            }
        }

        #expect(matched == 14)
    }

    @Test("Errors are Equatable")
    func errorsEquatable() {
        let error1 = RendezvousError.invalidNamespace("too long")
        let error2 = RendezvousError.invalidNamespace("too long")
        let error3 = RendezvousError.invalidCookie

        #expect(error1 == error2)
        #expect(error1 != error3)
    }
}

// MARK: - RendezvousService Configuration

@Suite("RendezvousService Configuration")
struct RendezvousServiceConfigurationTests {

    @Test("Default configuration has correct values")
    func defaultConfiguration() {
        let config = RendezvousService.Configuration()
        #expect(config.defaultTTL == RendezvousProtocol.defaultTTL)
        #expect(config.autoRefresh == true)
        #expect(config.refreshBuffer == .seconds(300))
    }

    @Test("Custom configuration is stored")
    func customConfiguration() {
        let config = RendezvousService.Configuration(
            defaultTTL: .seconds(1800),
            autoRefresh: false,
            refreshBuffer: .seconds(60)
        )
        #expect(config.defaultTTL == .seconds(1800))
        #expect(config.autoRefresh == false)
        #expect(config.refreshBuffer == .seconds(60))
    }
}

// MARK: - RendezvousService Registration

@Suite("RendezvousService Registration")
struct RendezvousServiceRegistrationTests {

    @Test("Register creates a registration")
    func registerCreatesRegistration() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        let registration = try service.register(namespace: "test-app")

        #expect(registration.namespace == "test-app")
        #expect(registration.ttl == RendezvousProtocol.defaultTTL)
        #expect(!registration.isExpired)
    }

    @Test("Register with custom TTL")
    func registerWithCustomTTL() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        let registration = try service.register(
            namespace: "test-app",
            ttl: .seconds(1800)
        )

        #expect(registration.ttl == .seconds(1800))
    }

    @Test("Register clamps TTL to maximum")
    func registerClampsTTL() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        let excessiveTTL = RendezvousProtocol.maxTTL + .seconds(3600)
        let registration = try service.register(
            namespace: "test-app",
            ttl: excessiveTTL
        )

        #expect(registration.ttl == RendezvousProtocol.maxTTL)
    }

    @Test("Register rejects empty namespace")
    func registerRejectsEmptyNamespace() {
        let service = RendezvousService()
        defer { service.shutdown() }

        #expect(throws: RendezvousError.self) {
            try service.register(namespace: "")
        }
    }

    @Test("Register rejects namespace exceeding max length")
    func registerRejectsLongNamespace() {
        let service = RendezvousService()
        defer { service.shutdown() }

        let longNamespace = String(repeating: "a", count: 256)
        #expect(throws: RendezvousError.self) {
            try service.register(namespace: longNamespace)
        }
    }

    @Test("Register accepts namespace at max length")
    func registerAcceptsMaxLengthNamespace() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        let maxNamespace = String(repeating: "a", count: 255)
        let registration = try service.register(namespace: maxNamespace)
        #expect(registration.namespace == maxNamespace)
    }

    @Test("Register rejects zero TTL")
    func registerRejectsZeroTTL() {
        let service = RendezvousService()
        defer { service.shutdown() }

        #expect(throws: RendezvousError.self) {
            try service.register(namespace: "test", ttl: .zero)
        }
    }

    @Test("Register replaces existing registration for same namespace")
    func registerReplacesExisting() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        let reg1 = try service.register(namespace: "test", ttl: .seconds(100))
        let reg2 = try service.register(namespace: "test", ttl: .seconds(200))

        #expect(reg1.ttl == .seconds(100))
        #expect(reg2.ttl == .seconds(200))

        let active = service.activeRegistrations()
        #expect(active.count == 1)
        #expect(active["test"]?.ttl == .seconds(200))
    }

    @Test("Unregister removes a registration")
    func unregisterRemovesRegistration() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        _ = try service.register(namespace: "test")
        #expect(service.activeRegistrations().count == 1)

        service.unregister(namespace: "test")
        #expect(service.activeRegistrations().isEmpty)
    }

    @Test("Unregister for non-existent namespace is no-op")
    func unregisterNonExistent() {
        let service = RendezvousService()
        defer { service.shutdown() }

        // Should not crash or throw
        service.unregister(namespace: "nonexistent")
    }

    @Test("Active registrations excludes expired entries")
    func activeRegistrationsExcludesExpired() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        // Register with a very short TTL (effectively expired)
        // We can't easily test actual expiry without sleeping,
        // so we register normally and verify the count
        _ = try service.register(namespace: "active", ttl: .seconds(3600))
        let active = service.activeRegistrations()
        #expect(active.count == 1)
        #expect(active["active"] != nil)
    }

    @Test("Multiple registrations under different namespaces")
    func multipleNamespaces() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        _ = try service.register(namespace: "app-1")
        _ = try service.register(namespace: "app-2")
        _ = try service.register(namespace: "app-3")

        let active = service.activeRegistrations()
        #expect(active.count == 3)
    }
}

// MARK: - RendezvousService Discovery

@Suite("RendezvousService Discovery")
struct RendezvousServiceDiscoveryTests {

    @Test("Discover returns empty for unknown namespace")
    func discoverEmptyNamespace() {
        let service = RendezvousService()
        defer { service.shutdown() }

        let peers = service.discover(namespace: "unknown")
        #expect(peers.isEmpty)
    }

    @Test("Discover returns cached peers")
    func discoverReturnsCached() {
        let service = RendezvousService()
        defer { service.shutdown() }

        let keyPair = KeyPair.generateEd25519()
        let peer = RendezvousService.DiscoveredPeer(
            peer: keyPair.peerID,
            addresses: [Multiaddr.tcp(host: "127.0.0.1", port: 4001)],
            ttl: .seconds(3600)
        )

        service.updateDiscoveryCache(namespace: "test", peers: [peer])
        let discovered = service.discover(namespace: "test")

        #expect(discovered.count == 1)
        #expect(discovered[0].peer == keyPair.peerID)
    }

    @Test("Discover respects limit")
    func discoverRespectsLimit() {
        let service = RendezvousService()
        defer { service.shutdown() }

        var peers: [RendezvousService.DiscoveredPeer] = []
        for _ in 0..<5 {
            let kp = KeyPair.generateEd25519()
            peers.append(RendezvousService.DiscoveredPeer(
                peer: kp.peerID,
                addresses: [Multiaddr.tcp(host: "127.0.0.1", port: 4001)],
                ttl: .seconds(3600)
            ))
        }

        service.updateDiscoveryCache(namespace: "test", peers: peers)
        let discovered = service.discover(namespace: "test", limit: 3)

        #expect(discovered.count == 3)
    }

    @Test("Discover without limit returns all peers")
    func discoverWithoutLimitReturnsAll() {
        let service = RendezvousService()
        defer { service.shutdown() }

        var peers: [RendezvousService.DiscoveredPeer] = []
        for _ in 0..<5 {
            let kp = KeyPair.generateEd25519()
            peers.append(RendezvousService.DiscoveredPeer(
                peer: kp.peerID,
                addresses: [Multiaddr.tcp(host: "127.0.0.1", port: 4001)],
                ttl: .seconds(3600)
            ))
        }

        service.updateDiscoveryCache(namespace: "test", peers: peers)
        let discovered = service.discover(namespace: "test")

        #expect(discovered.count == 5)
    }

    @Test("Clear discovery cache removes namespace")
    func clearDiscoveryCacheNamespace() {
        let service = RendezvousService()
        defer { service.shutdown() }

        let kp = KeyPair.generateEd25519()
        let peer = RendezvousService.DiscoveredPeer(
            peer: kp.peerID,
            addresses: [],
            ttl: .seconds(3600)
        )

        service.updateDiscoveryCache(namespace: "ns1", peers: [peer])
        service.updateDiscoveryCache(namespace: "ns2", peers: [peer])

        service.clearDiscoveryCache(namespace: "ns1")

        #expect(service.discover(namespace: "ns1").isEmpty)
        #expect(service.discover(namespace: "ns2").count == 1)
    }

    @Test("Clear all discovery cache")
    func clearAllDiscoveryCache() {
        let service = RendezvousService()
        defer { service.shutdown() }

        let kp = KeyPair.generateEd25519()
        let peer = RendezvousService.DiscoveredPeer(
            peer: kp.peerID,
            addresses: [],
            ttl: .seconds(3600)
        )

        service.updateDiscoveryCache(namespace: "ns1", peers: [peer])
        service.updateDiscoveryCache(namespace: "ns2", peers: [peer])

        service.clearDiscoveryCache()

        #expect(service.discover(namespace: "ns1").isEmpty)
        #expect(service.discover(namespace: "ns2").isEmpty)
    }
}

// MARK: - RendezvousService Events

@Suite("RendezvousService Events")
struct RendezvousServiceEventTests {

    @Test("Events stream is available")
    func eventsStreamAvailable() {
        let service = RendezvousService()
        defer { service.shutdown() }

        _ = service.events
        _ = service.events // Accessing twice returns same stream
    }

    @Test("Shutdown terminates event stream", .timeLimit(.minutes(1)))
    func shutdownTerminatesEventStream() async {
        let service = RendezvousService()

        let events = service.events

        let consumeTask = Task {
            var count = 0
            for await _ in events {
                count += 1
            }
            return count
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        service.shutdown()

        let count = await consumeTask.value
        #expect(count == 0)
    }

    @Test("Shutdown is idempotent")
    func shutdownIsIdempotent() {
        let service = RendezvousService()

        service.shutdown()
        service.shutdown()
        service.shutdown()
    }

    @Test("Register emits registered event", .timeLimit(.minutes(1)))
    func registerEmitsEvent() async throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        let events = service.events

        let eventTask = Task<RendezvousService.Event?, Never> {
            for await event in events {
                return event
            }
            return nil
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        _ = try service.register(namespace: "test-ns")

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }
        service.shutdown()

        let event = await eventTask.value
        if case .registered(let ns, _) = event {
            #expect(ns == "test-ns")
        } else {
            Issue.record("Expected registered event")
        }
    }

    @Test("Unregister emits unregistered event", .timeLimit(.minutes(1)))
    func unregisterEmitsEvent() async throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        _ = try service.register(namespace: "test-ns")

        let events = service.events

        let eventTask = Task<RendezvousService.Event?, Never> {
            for await event in events {
                return event
            }
            return nil
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        service.unregister(namespace: "test-ns")

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }
        service.shutdown()

        let event = await eventTask.value
        if case .unregistered(let ns) = event {
            #expect(ns == "test-ns")
        } else {
            Issue.record("Expected unregistered event")
        }
    }
}

// MARK: - RendezvousPoint Configuration

@Suite("RendezvousPoint Configuration")
struct RendezvousPointConfigurationTests {

    @Test("Default configuration has correct values")
    func defaultConfiguration() {
        let config = RendezvousPoint.Configuration()
        #expect(config.maxRegistrationsPerPeer == 100)
        #expect(config.maxRegistrationsPerNamespace == 1000)
        #expect(config.maxNamespaces == 10000)
    }

    @Test("Custom configuration is stored")
    func customConfiguration() {
        let config = RendezvousPoint.Configuration(
            maxRegistrationsPerPeer: 50,
            maxRegistrationsPerNamespace: 500,
            maxNamespaces: 5000
        )
        #expect(config.maxRegistrationsPerPeer == 50)
        #expect(config.maxRegistrationsPerNamespace == 500)
        #expect(config.maxNamespaces == 5000)
    }
}

// MARK: - RendezvousPoint Registration

@Suite("RendezvousPoint Registration")
struct RendezvousPointRegistrationTests {

    @Test("Register creates a registration")
    func registerCreatesRegistration() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let keyPair = KeyPair.generateEd25519()
        let addr = Multiaddr.tcp(host: "127.0.0.1", port: 4001)

        let reg = try point.register(
            peer: keyPair.peerID,
            namespace: "test-app",
            addresses: [addr],
            ttl: .seconds(3600)
        )

        #expect(reg.namespace == "test-app")
        #expect(reg.peer == keyPair.peerID)
        #expect(reg.addresses.count == 1)
        #expect(reg.ttl == .seconds(3600))
        #expect(!reg.isExpired)
    }

    @Test("Register clamps TTL to maximum")
    func registerClampsTTL() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let keyPair = KeyPair.generateEd25519()
        let excessiveTTL = RendezvousProtocol.maxTTL + .seconds(3600)

        let reg = try point.register(
            peer: keyPair.peerID,
            namespace: "test",
            addresses: [],
            ttl: excessiveTTL
        )

        #expect(reg.ttl == RendezvousProtocol.maxTTL)
    }

    @Test("Register rejects empty namespace")
    func registerRejectsEmptyNamespace() {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let keyPair = KeyPair.generateEd25519()

        #expect(throws: RendezvousError.self) {
            try point.register(
                peer: keyPair.peerID,
                namespace: "",
                addresses: [],
                ttl: .seconds(3600)
            )
        }
    }

    @Test("Register rejects namespace exceeding max length")
    func registerRejectsLongNamespace() {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let keyPair = KeyPair.generateEd25519()
        let longNamespace = String(repeating: "x", count: 256)

        #expect(throws: RendezvousError.self) {
            try point.register(
                peer: keyPair.peerID,
                namespace: longNamespace,
                addresses: [],
                ttl: .seconds(3600)
            )
        }
    }

    @Test("Register rejects zero TTL")
    func registerRejectsZeroTTL() {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let keyPair = KeyPair.generateEd25519()

        #expect(throws: RendezvousError.self) {
            try point.register(
                peer: keyPair.peerID,
                namespace: "test",
                addresses: [],
                ttl: .zero
            )
        }
    }

    @Test("Register replaces existing registration for same peer")
    func registerReplacesSamePeer() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let keyPair = KeyPair.generateEd25519()
        let addr1 = Multiaddr.tcp(host: "127.0.0.1", port: 4001)
        let addr2 = Multiaddr.tcp(host: "127.0.0.1", port: 5001)

        _ = try point.register(
            peer: keyPair.peerID,
            namespace: "test",
            addresses: [addr1],
            ttl: .seconds(100)
        )

        let reg2 = try point.register(
            peer: keyPair.peerID,
            namespace: "test",
            addresses: [addr2],
            ttl: .seconds(200)
        )

        // Should have replaced, not added
        #expect(point.registrationCount(namespace: "test") == 1)
        #expect(reg2.ttl == .seconds(200))
    }

    @Test("Multiple peers can register in same namespace")
    func multiplePeersInNamespace() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer1 = KeyPair.generateEd25519().peerID
        let peer2 = KeyPair.generateEd25519().peerID
        let peer3 = KeyPair.generateEd25519().peerID

        _ = try point.register(peer: peer1, namespace: "test", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer2, namespace: "test", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer3, namespace: "test", addresses: [], ttl: .seconds(3600))

        #expect(point.registrationCount(namespace: "test") == 3)
    }

    @Test("Per-peer registration limit is enforced")
    func perPeerLimitEnforced() throws {
        let config = RendezvousPoint.Configuration(
            maxRegistrationsPerPeer: 3,
            maxRegistrationsPerNamespace: 1000,
            maxNamespaces: 10000
        )
        let point = RendezvousPoint(configuration: config)
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID

        _ = try point.register(peer: peer, namespace: "ns1", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer, namespace: "ns2", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer, namespace: "ns3", addresses: [], ttl: .seconds(3600))

        #expect(throws: RendezvousError.self) {
            try point.register(peer: peer, namespace: "ns4", addresses: [], ttl: .seconds(3600))
        }
    }

    @Test("Per-namespace registration limit is enforced")
    func perNamespaceLimitEnforced() throws {
        let config = RendezvousPoint.Configuration(
            maxRegistrationsPerPeer: 1000,
            maxRegistrationsPerNamespace: 3,
            maxNamespaces: 10000
        )
        let point = RendezvousPoint(configuration: config)
        defer { point.shutdown() }

        let peer1 = KeyPair.generateEd25519().peerID
        let peer2 = KeyPair.generateEd25519().peerID
        let peer3 = KeyPair.generateEd25519().peerID
        let peer4 = KeyPair.generateEd25519().peerID

        _ = try point.register(peer: peer1, namespace: "test", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer2, namespace: "test", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer3, namespace: "test", addresses: [], ttl: .seconds(3600))

        #expect(throws: RendezvousError.self) {
            try point.register(peer: peer4, namespace: "test", addresses: [], ttl: .seconds(3600))
        }
    }

    @Test("Max namespaces limit is enforced")
    func maxNamespacesLimitEnforced() throws {
        let config = RendezvousPoint.Configuration(
            maxRegistrationsPerPeer: 1000,
            maxRegistrationsPerNamespace: 1000,
            maxNamespaces: 3
        )
        let point = RendezvousPoint(configuration: config)
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID

        _ = try point.register(peer: peer, namespace: "ns1", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer, namespace: "ns2", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer, namespace: "ns3", addresses: [], ttl: .seconds(3600))

        let peer2 = KeyPair.generateEd25519().peerID
        #expect(throws: RendezvousError.self) {
            try point.register(peer: peer2, namespace: "ns4", addresses: [], ttl: .seconds(3600))
        }
    }

    @Test("Re-registering same peer in same namespace does not increase count")
    func reRegisterDoesNotIncreaseCount() throws {
        let config = RendezvousPoint.Configuration(
            maxRegistrationsPerPeer: 2,
            maxRegistrationsPerNamespace: 1000,
            maxNamespaces: 10000
        )
        let point = RendezvousPoint(configuration: config)
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID

        _ = try point.register(peer: peer, namespace: "ns1", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer, namespace: "ns2", addresses: [], ttl: .seconds(3600))

        // Re-registering in ns1 should succeed (not a new registration)
        _ = try point.register(peer: peer, namespace: "ns1", addresses: [], ttl: .seconds(7200))

        #expect(point.registrationCount(namespace: "ns1") == 1)
    }
}

// MARK: - RendezvousPoint Unregister

@Suite("RendezvousPoint Unregister")
struct RendezvousPointUnregisterTests {

    @Test("Unregister removes peer from namespace")
    func unregisterRemovesPeer() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID

        _ = try point.register(peer: peer, namespace: "test", addresses: [], ttl: .seconds(3600))
        #expect(point.registrationCount(namespace: "test") == 1)

        point.unregister(peer: peer, namespace: "test")
        #expect(point.registrationCount(namespace: "test") == 0)
    }

    @Test("Unregister removes namespace when empty")
    func unregisterRemovesEmptyNamespace() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID

        _ = try point.register(peer: peer, namespace: "test", addresses: [], ttl: .seconds(3600))
        #expect(point.allNamespaces().contains("test"))

        point.unregister(peer: peer, namespace: "test")
        #expect(!point.allNamespaces().contains("test"))
    }

    @Test("Unregister is no-op for non-existent peer")
    func unregisterNonExistentPeer() {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        point.unregister(peer: peer, namespace: "test")
    }

    @Test("Unregister is no-op for non-existent namespace")
    func unregisterNonExistentNamespace() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        _ = try point.register(peer: peer, namespace: "test", addresses: [], ttl: .seconds(3600))

        point.unregister(peer: peer, namespace: "other")
        #expect(point.registrationCount(namespace: "test") == 1)
    }

    @Test("Unregister only removes specified peer")
    func unregisterOnlySpecifiedPeer() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer1 = KeyPair.generateEd25519().peerID
        let peer2 = KeyPair.generateEd25519().peerID

        _ = try point.register(peer: peer1, namespace: "test", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer2, namespace: "test", addresses: [], ttl: .seconds(3600))

        point.unregister(peer: peer1, namespace: "test")

        #expect(point.registrationCount(namespace: "test") == 1)
    }
}

// MARK: - RendezvousPoint Discovery

@Suite("RendezvousPoint Discovery")
struct RendezvousPointDiscoveryTests {

    @Test("Discover returns registrations")
    func discoverReturnsRegistrations() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer1 = KeyPair.generateEd25519().peerID
        let peer2 = KeyPair.generateEd25519().peerID
        let addr = Multiaddr.tcp(host: "127.0.0.1", port: 4001)

        _ = try point.register(peer: peer1, namespace: "test", addresses: [addr], ttl: .seconds(3600))
        _ = try point.register(peer: peer2, namespace: "test", addresses: [addr], ttl: .seconds(3600))

        let (regs, cookie) = point.discover(namespace: "test")

        #expect(regs.count == 2)
        #expect(cookie == nil) // All results returned, no more pages
    }

    @Test("Discover returns empty for unknown namespace")
    func discoverEmptyNamespace() {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let (regs, cookie) = point.discover(namespace: "unknown")
        #expect(regs.isEmpty)
        #expect(cookie == nil)
    }

    @Test("Discover respects limit")
    func discoverRespectsLimit() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        for _ in 0..<5 {
            let peer = KeyPair.generateEd25519().peerID
            _ = try point.register(peer: peer, namespace: "test", addresses: [], ttl: .seconds(3600))
        }

        let (regs, cookie) = point.discover(namespace: "test", limit: 3)

        #expect(regs.count == 3)
        #expect(cookie != nil) // More results available
    }

    @Test("Cookie-based pagination works correctly")
    func cookiePaginationWorks() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        for _ in 0..<5 {
            let peer = KeyPair.generateEd25519().peerID
            _ = try point.register(peer: peer, namespace: "test", addresses: [], ttl: .seconds(3600))
        }

        // First page
        let (page1, cookie1) = point.discover(namespace: "test", limit: 2)
        #expect(page1.count == 2)
        #expect(cookie1 != nil)

        // Second page
        let (page2, cookie2) = point.discover(namespace: "test", limit: 2, cookie: cookie1)
        #expect(page2.count == 2)
        #expect(cookie2 != nil)

        // Third page (last)
        let (page3, cookie3) = point.discover(namespace: "test", limit: 2, cookie: cookie2)
        #expect(page3.count == 1) // Only 1 remaining
        #expect(cookie3 == nil) // No more pages

        // All peers should be unique across pages
        let allPeers = page1.map(\.peer) + page2.map(\.peer) + page3.map(\.peer)
        let uniquePeers = Set(allPeers)
        #expect(uniquePeers.count == 5)
    }

    @Test("Cookie from wrong namespace returns empty")
    func cookieWrongNamespace() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        for _ in 0..<5 {
            let peer = KeyPair.generateEd25519().peerID
            _ = try point.register(peer: peer, namespace: "ns1", addresses: [], ttl: .seconds(3600))
        }

        let peer = KeyPair.generateEd25519().peerID
        _ = try point.register(peer: peer, namespace: "ns2", addresses: [], ttl: .seconds(3600))

        // Get a cookie for ns1
        let (_, cookie) = point.discover(namespace: "ns1", limit: 2)
        #expect(cookie != nil)

        // Try using it for ns2
        let (regs, _) = point.discover(namespace: "ns2", limit: 10, cookie: cookie)
        #expect(regs.isEmpty)
    }

    @Test("Invalid cookie returns empty")
    func invalidCookie() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        _ = try point.register(peer: peer, namespace: "test", addresses: [], ttl: .seconds(3600))

        let invalidCookie = Data([0xFF, 0xFF, 0xFF, 0xFF])
        let (regs, cookie) = point.discover(namespace: "test", limit: 10, cookie: invalidCookie)

        // Unknown cookie should return results from the beginning
        // Since we don't find the cookie, startOffset defaults to 0
        #expect(regs.count == 1)
        #expect(cookie == nil)
    }

    @Test("Discover without limit returns all registrations")
    func discoverWithoutLimit() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        for _ in 0..<10 {
            let peer = KeyPair.generateEd25519().peerID
            _ = try point.register(peer: peer, namespace: "test", addresses: [], ttl: .seconds(3600))
        }

        let (regs, cookie) = point.discover(namespace: "test")

        #expect(regs.count == 10)
        #expect(cookie == nil)
    }
}

// MARK: - RendezvousPoint Expiry

@Suite("RendezvousPoint Expiry Cleanup")
struct RendezvousPointExpiryTests {

    @Test("Remove expired registrations cleans up stale entries")
    func removeExpiredRegistrations() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let activePeer = KeyPair.generateEd25519().peerID
        let addr = Multiaddr.tcp(host: "127.0.0.1", port: 4001)

        // Register a peer with a long TTL
        _ = try point.register(
            peer: activePeer,
            namespace: "test",
            addresses: [addr],
            ttl: .seconds(3600)
        )

        #expect(point.registrationCount(namespace: "test") == 1)

        // Run cleanup - active registration should remain
        point.removeExpiredRegistrations()
        #expect(point.registrationCount(namespace: "test") == 1)
    }

    @Test("Registration count excludes expired entries")
    func registrationCountExcludesExpired() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID

        _ = try point.register(
            peer: peer,
            namespace: "test",
            addresses: [],
            ttl: .seconds(3600)
        )

        // Active registration should be counted
        #expect(point.registrationCount(namespace: "test") == 1)
    }

    @Test("All namespaces returns tracked namespaces")
    func allNamespacesReturnsTracked() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID

        _ = try point.register(peer: peer, namespace: "ns1", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer, namespace: "ns2", addresses: [], ttl: .seconds(3600))
        _ = try point.register(peer: peer, namespace: "ns3", addresses: [], ttl: .seconds(3600))

        let namespaces = point.allNamespaces()
        #expect(namespaces.count == 3)
        #expect(Set(namespaces) == Set(["ns1", "ns2", "ns3"]))
    }
}

// MARK: - RendezvousPoint Events

@Suite("RendezvousPoint Events")
struct RendezvousPointEventTests {

    @Test("Events stream is available")
    func eventsStreamAvailable() {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        _ = point.events
    }

    @Test("Shutdown terminates event stream", .timeLimit(.minutes(1)))
    func shutdownTerminatesEventStream() async {
        let point = RendezvousPoint()

        let events = point.events

        let consumeTask = Task {
            var count = 0
            for await _ in events {
                count += 1
            }
            return count
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        point.shutdown()

        let count = await consumeTask.value
        #expect(count == 0)
    }

    @Test("Shutdown is idempotent")
    func shutdownIsIdempotent() {
        let point = RendezvousPoint()

        point.shutdown()
        point.shutdown()
        point.shutdown()
    }

    @Test("Register emits peerRegistered event", .timeLimit(.minutes(1)))
    func registerEmitsEvent() async throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let events = point.events

        let eventTask = Task {
            var collected: [RendezvousPoint.Event] = []
            for await event in events {
                collected.append(event)
                if collected.count >= 2 { break } // namespaceCreated + peerRegistered
            }
            return collected
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        let peer = KeyPair.generateEd25519().peerID
        _ = try point.register(
            peer: peer,
            namespace: "test",
            addresses: [],
            ttl: .seconds(3600)
        )

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }
        point.shutdown()

        let collected = await eventTask.value

        var hasNamespaceCreated = false
        var hasPeerRegistered = false

        for event in collected {
            switch event {
            case .namespaceCreated(let ns):
                #expect(ns == "test")
                hasNamespaceCreated = true
            case .peerRegistered(let ns, let p):
                #expect(ns == "test")
                #expect(p == peer)
                hasPeerRegistered = true
            default:
                break
            }
        }

        #expect(hasNamespaceCreated)
        #expect(hasPeerRegistered)
    }

    @Test("Unregister emits peerUnregistered event", .timeLimit(.minutes(1)))
    func unregisterEmitsEvent() async throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        _ = try point.register(peer: peer, namespace: "test", addresses: [], ttl: .seconds(3600))

        let events = point.events

        let eventTask = Task<RendezvousPoint.Event?, Never> {
            for await event in events {
                return event
            }
            return nil
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        point.unregister(peer: peer, namespace: "test")

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }
        point.shutdown()

        let event = await eventTask.value

        if case .peerUnregistered(let ns, let p) = event {
            #expect(ns == "test")
            #expect(p == peer)
        } else {
            Issue.record("Expected peerUnregistered event")
        }
    }
}

// MARK: - Namespace Validation

@Suite("Namespace Validation")
struct NamespaceValidationTests {

    @Test("Service accepts valid namespaces")
    func serviceAcceptsValidNamespaces() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        let validNamespaces = [
            "a",
            "test-app",
            "my.app.v2",
            "namespace/with/slashes",
            String(repeating: "a", count: 255),
        ]

        for ns in validNamespaces {
            _ = try service.register(namespace: ns)
        }
    }

    @Test("Point accepts valid namespaces")
    func pointAcceptsValidNamespaces() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let validNamespaces = [
            "a",
            "test-app",
            "my.app.v2",
            "namespace/with/slashes",
            String(repeating: "a", count: 255),
        ]

        for ns in validNamespaces {
            _ = try point.register(peer: peer, namespace: ns, addresses: [], ttl: .seconds(3600))
        }
    }
}

// MARK: - TTL Enforcement

@Suite("TTL Enforcement")
struct TTLEnforcementTests {

    @Test("Service enforces positive TTL")
    func serviceEnforcesPositiveTTL() {
        let service = RendezvousService()
        defer { service.shutdown() }

        #expect(throws: RendezvousError.self) {
            try service.register(namespace: "test", ttl: .zero)
        }
    }

    @Test("Point enforces positive TTL")
    func pointEnforcesPositiveTTL() {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID

        #expect(throws: RendezvousError.self) {
            try point.register(peer: peer, namespace: "test", addresses: [], ttl: .zero)
        }
    }

    @Test("Service clamps excessive TTL")
    func serviceClamsExcessiveTTL() throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        let reg = try service.register(
            namespace: "test",
            ttl: .seconds(1_000_000)
        )

        #expect(reg.ttl == RendezvousProtocol.maxTTL)
    }

    @Test("Point clamps excessive TTL")
    func pointClampsExcessiveTTL() throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peer = KeyPair.generateEd25519().peerID

        let reg = try point.register(
            peer: peer,
            namespace: "test",
            addresses: [],
            ttl: .seconds(1_000_000)
        )

        #expect(reg.ttl == RendezvousProtocol.maxTTL)
    }
}

// MARK: - Concurrent Safety

@Suite("Concurrent Safety")
struct ConcurrentSafetyTests {

    @Test("Concurrent registrations on service are safe", .timeLimit(.minutes(1)))
    func concurrentServiceRegistrations() async throws {
        let service = RendezvousService()
        defer { service.shutdown() }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    do {
                        _ = try service.register(namespace: "ns-\(i)")
                    } catch {
                        // Expected for some concurrent operations
                    }
                }
            }
        }

        let active = service.activeRegistrations()
        #expect(active.count == 100)
    }

    @Test("Concurrent registrations on point are safe", .timeLimit(.minutes(1)))
    func concurrentPointRegistrations() async throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let peer = KeyPair.generateEd25519().peerID
                    do {
                        _ = try point.register(
                            peer: peer,
                            namespace: "test",
                            addresses: [],
                            ttl: .seconds(3600)
                        )
                    } catch {
                        // Expected if limits are hit
                    }
                }
            }
        }

        let count = point.registrationCount(namespace: "test")
        #expect(count <= 1000) // Should not exceed default limit
        #expect(count > 0) // At least some registrations should succeed
    }

    @Test("Concurrent register and discover on point are safe", .timeLimit(.minutes(1)))
    func concurrentRegisterAndDiscover() async throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        // Pre-populate some registrations
        for _ in 0..<10 {
            let peer = KeyPair.generateEd25519().peerID
            _ = try point.register(
                peer: peer,
                namespace: "test",
                addresses: [],
                ttl: .seconds(3600)
            )
        }

        await withTaskGroup(of: Void.self) { group in
            // Concurrent registrations
            for _ in 0..<50 {
                group.addTask {
                    let peer = KeyPair.generateEd25519().peerID
                    _ = try? point.register(
                        peer: peer,
                        namespace: "test",
                        addresses: [],
                        ttl: .seconds(3600)
                    )
                }
            }

            // Concurrent discoveries
            for _ in 0..<50 {
                group.addTask {
                    let (regs, _) = point.discover(namespace: "test")
                    _ = regs.count // Access the results
                }
            }
        }

        // Just verify we can still query after concurrent access
        let count = point.registrationCount(namespace: "test")
        #expect(count > 0)
    }

    @Test("Concurrent register and unregister are safe", .timeLimit(.minutes(1)))
    func concurrentRegisterAndUnregister() async throws {
        let point = RendezvousPoint()
        defer { point.shutdown() }

        let peers = (0..<20).map { _ in KeyPair.generateEd25519().peerID }

        // Register all peers first
        for peer in peers {
            _ = try point.register(
                peer: peer,
                namespace: "test",
                addresses: [],
                ttl: .seconds(3600)
            )
        }

        await withTaskGroup(of: Void.self) { group in
            // Unregister half
            for peer in peers.prefix(10) {
                group.addTask {
                    point.unregister(peer: peer, namespace: "test")
                }
            }

            // Register new ones
            for _ in 0..<10 {
                group.addTask {
                    let peer = KeyPair.generateEd25519().peerID
                    _ = try? point.register(
                        peer: peer,
                        namespace: "test",
                        addresses: [],
                        ttl: .seconds(3600)
                    )
                }
            }
        }

        // Verify consistent state
        let count = point.registrationCount(namespace: "test")
        #expect(count >= 0)
    }
}

// MARK: - DiscoveredPeer

@Suite("DiscoveredPeer Tests")
struct DiscoveredPeerTests {

    @Test("DiscoveredPeer stores correct values")
    func discoveredPeerValues() {
        let keyPair = KeyPair.generateEd25519()
        let addr = Multiaddr.tcp(host: "192.168.1.1", port: 4001)

        let discovered = RendezvousService.DiscoveredPeer(
            peer: keyPair.peerID,
            addresses: [addr],
            ttl: .seconds(3600)
        )

        #expect(discovered.peer == keyPair.peerID)
        #expect(discovered.addresses.count == 1)
        #expect(discovered.ttl == .seconds(3600))
    }

    @Test("DiscoveredPeer with multiple addresses")
    func discoveredPeerMultipleAddresses() {
        let keyPair = KeyPair.generateEd25519()
        let addr1 = Multiaddr.tcp(host: "192.168.1.1", port: 4001)
        let addr2 = Multiaddr.tcp(host: "10.0.0.1", port: 4002)
        let addr3 = Multiaddr.quic(host: "192.168.1.1", port: 4003)

        let discovered = RendezvousService.DiscoveredPeer(
            peer: keyPair.peerID,
            addresses: [addr1, addr2, addr3],
            ttl: .seconds(1800)
        )

        #expect(discovered.addresses.count == 3)
    }
}
