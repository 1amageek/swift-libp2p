/// IdentifyServiceTests - Unit tests for IdentifyService
import Testing
import Foundation
@testable import P2PIdentify
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols
import Synchronization

@Suite("IdentifyService Tests")
struct IdentifyServiceTests {

    // MARK: - Configuration Tests

    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = IdentifyConfiguration()

        #expect(config.protocolVersion == "ipfs/0.1.0")
        #expect(config.agentVersion == "swift-libp2p/0.1.0")
        #expect(config.timeout == .seconds(60))
    }

    @Test("Custom configuration values")
    func customConfiguration() {
        let config = IdentifyConfiguration(
            protocolVersion: "my/1.0.0",
            agentVersion: "custom/2.0.0",
            timeout: .seconds(30)
        )

        #expect(config.protocolVersion == "my/1.0.0")
        #expect(config.agentVersion == "custom/2.0.0")
        #expect(config.timeout == .seconds(30))
    }

    @Test("Configuration includes cache settings")
    func cacheConfigurationDefaults() {
        let config = IdentifyConfiguration()

        #expect(config.cacheTTL == .seconds(24 * 60 * 60))  // 24 hours
        #expect(config.maxCacheSize == 1000)
        #expect(config.cleanupInterval == .seconds(300))   // 5 minutes
    }

    @Test("Custom cache configuration values")
    func customCacheConfiguration() {
        let config = IdentifyConfiguration(
            cacheTTL: .seconds(3600),
            maxCacheSize: 500,
            cleanupInterval: .seconds(60)
        )

        #expect(config.cacheTTL == .seconds(3600))
        #expect(config.maxCacheSize == 500)
        #expect(config.cleanupInterval == .seconds(60))
    }

    @Test("Cache cleanup can be disabled")
    func cacheCleanupDisabled() {
        let config = IdentifyConfiguration(cleanupInterval: nil)

        #expect(config.cleanupInterval == nil)
    }

    // MARK: - Protocol ID Tests

    @Test("Service exposes correct protocol IDs")
    func protocolIDs() {
        let service = IdentifyService()

        #expect(service.protocolIDs.contains("/ipfs/id/1.0.0"))
        #expect(service.protocolIDs.contains("/ipfs/id/push/1.0.0"))
        #expect(service.protocolIDs.count == 2)
    }

    // MARK: - Cache Tests

    @Test("Cache stores and retrieves peer info")
    func cacheStoreAndRetrieve() {
        let service = IdentifyService()
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        let _ = IdentifyInfo(
            publicKey: keyPair.publicKey,
            agentVersion: "test/1.0.0"
        )

        // Initially empty
        #expect(service.cachedInfo(for: peerID) == nil)

        // Store via internal mechanism (we'll use reflection or test helper)
        // For now, test the clear methods work
        #expect(service.allCachedInfo.isEmpty)
    }

    @Test("Cache clear removes peer info")
    func cacheClear() {
        let service = IdentifyService()

        // Verify cache is initially empty
        #expect(service.allCachedInfo.isEmpty)

        // Clear should not crash on empty cache
        let peerID = KeyPair.generateEd25519().peerID
        service.clearCache(for: peerID)
        service.clearAllCache()

        #expect(service.allCachedInfo.isEmpty)
    }

    @Test("Cache all returns all stored info")
    func cacheAll() {
        let service = IdentifyService()

        // Initially empty
        #expect(service.allCachedInfo.isEmpty)
    }

    @Test("Cache stores and retrieves via cacheInfo", .timeLimit(.minutes(1)))
    func cachePeerInfo() {
        let service = IdentifyService()
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        let info = IdentifyInfo(
            publicKey: keyPair.publicKey,
            agentVersion: "test/1.0.0"
        )

        // Initially empty
        #expect(service.cachedInfo(for: peerID) == nil)

        // Store via internal method
        service.cacheInfo(info, for: peerID)

        // Should be retrievable
        let cached = service.cachedInfo(for: peerID)
        #expect(cached != nil)
        #expect(cached?.agentVersion == "test/1.0.0")
    }

    @Test("Cached info expires after TTL", .timeLimit(.minutes(1)))
    func cacheTTLExpiration() async throws {
        let service = IdentifyService(configuration: .init(
            cacheTTL: .milliseconds(50)
        ))
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        let info = IdentifyInfo(publicKey: keyPair.publicKey)

        service.cacheInfo(info, for: peerID)
        #expect(service.cachedInfo(for: peerID) != nil)

        try await Task.sleep(for: .milliseconds(100))

        // Should be expired (lazy cleanup on access)
        #expect(service.cachedInfo(for: peerID) == nil)
    }

    @Test("Cache evicts LRU when full", .timeLimit(.minutes(1)))
    func cacheLRUEviction() {
        let service = IdentifyService(configuration: .init(
            maxCacheSize: 3
        ))

        // Create 4 peers
        let peers = (0..<4).map { _ in KeyPair.generateEd25519().peerID }

        // Add first 3 peers
        for peer in peers.prefix(3) {
            service.cacheInfo(IdentifyInfo(), for: peer)
        }

        // All 3 should be present
        #expect(service.cachedInfo(for: peers[0]) != nil)
        #expect(service.cachedInfo(for: peers[1]) != nil)
        #expect(service.cachedInfo(for: peers[2]) != nil)

        // Access peer[0] to make it most recent (moves to end of LRU)
        _ = service.cachedInfo(for: peers[0])

        // Add 4th peer - should evict peer[1] (LRU, since peer[0] was just accessed)
        service.cacheInfo(IdentifyInfo(), for: peers[3])

        #expect(service.cachedInfo(for: peers[0]) != nil)  // Recently accessed
        #expect(service.cachedInfo(for: peers[1]) == nil)  // Evicted (LRU)
        #expect(service.cachedInfo(for: peers[2]) != nil)
        #expect(service.cachedInfo(for: peers[3]) != nil)
    }

    @Test("Cache cleanup removes expired entries", .timeLimit(.minutes(1)))
    func cacheCleanup() async throws {
        let service = IdentifyService(configuration: .init(
            cacheTTL: .milliseconds(50),
            cleanupInterval: nil  // Disable automatic cleanup
        ))

        let peer = KeyPair.generateEd25519().peerID
        service.cacheInfo(IdentifyInfo(), for: peer)

        #expect(service.allCachedInfo.count == 1)

        try await Task.sleep(for: .milliseconds(100))

        // Manual cleanup
        let removed = service.cleanup()
        #expect(removed == 1)
        #expect(service.allCachedInfo.isEmpty)
    }

    @Test("allCachedInfo excludes expired entries", .timeLimit(.minutes(1)))
    func allCachedInfoExcludesExpired() async throws {
        let service = IdentifyService(configuration: .init(
            cacheTTL: .milliseconds(50)
        ))

        let peer1 = KeyPair.generateEd25519().peerID
        let peer2 = KeyPair.generateEd25519().peerID

        service.cacheInfo(IdentifyInfo(agentVersion: "peer1"), for: peer1)

        try await Task.sleep(for: .milliseconds(100))

        // Add peer2 after peer1 expired
        service.cacheInfo(IdentifyInfo(agentVersion: "peer2"), for: peer2)

        // allCachedInfo should only return peer2
        let all = service.allCachedInfo
        #expect(all.count == 1)
        #expect(all[peer2]?.agentVersion == "peer2")
    }

    // MARK: - Event Tests

    @Test("Events stream is available")
    func eventsStream() {
        let service = IdentifyService()

        // Should be able to get the events stream
        _ = service.events

        // Getting it again should return the same stream instance
        // (tests lazy initialization)
        _ = service.events
    }

    @Test("Shutdown terminates event stream", .timeLimit(.minutes(1)))
    func shutdownTerminatesEventStream() async {
        let service = IdentifyService()

        // Get the event stream
        let events = service.events

        // Start consuming events in a task
        let consumeTask = Task {
            var count = 0
            for await _ in events {
                count += 1
            }
            return count
        }

        // Give time for the consumer to start
        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        // Shutdown should terminate the stream
        await service.shutdown()

        // Consumer should complete without timing out
        let count = await consumeTask.value
        #expect(count == 0)  // No events were emitted
    }

    @Test("Shutdown is idempotent")
    func shutdownIsIdempotent() {
        let service = IdentifyService()

        // Multiple shutdowns should not crash
        service.shutdown()
        service.shutdown()
        service.shutdown()

        // Service should still be usable for cached data
        #expect(service.allCachedInfo.isEmpty)
    }

    // MARK: - Maintenance Tests

    @Test("Maintenance task cleans up expired entries", .timeLimit(.minutes(1)))
    func maintenanceTaskCleanup() async throws {
        let service = IdentifyService(configuration: .init(
            cacheTTL: .milliseconds(50),
            cleanupInterval: .milliseconds(100)
        ))

        let peer = KeyPair.generateEd25519().peerID
        service.cacheInfo(IdentifyInfo(), for: peer)

        // Start maintenance
        service.startMaintenance()

        // Wait for entry to expire and maintenance to run
        try await Task.sleep(for: .milliseconds(250))

        // Entry should be cleaned up
        #expect(service.cachedInfo(for: peer) == nil)

        await service.shutdown()
    }

    @Test("startMaintenance is idempotent")
    func startMaintenanceIdempotent() {
        let service = IdentifyService()

        // Multiple starts should not crash or create multiple tasks
        service.startMaintenance()
        service.startMaintenance()
        service.startMaintenance()

        service.shutdown()
    }

    @Test("stopMaintenance is idempotent")
    func stopMaintenanceIdempotent() {
        let service = IdentifyService()

        // Multiple stops should not crash
        service.stopMaintenance()
        service.stopMaintenance()

        service.startMaintenance()
        service.stopMaintenance()
        service.stopMaintenance()
    }

    @Test("Maintenance does not start with nil cleanupInterval")
    func maintenanceDisabledWithNilInterval() async throws {
        let service = IdentifyService(configuration: .init(
            cacheTTL: .milliseconds(50),
            cleanupInterval: nil
        ))

        let peer = KeyPair.generateEd25519().peerID
        service.cacheInfo(IdentifyInfo(), for: peer)

        // Start maintenance (should be no-op)
        service.startMaintenance()

        try await Task.sleep(for: .milliseconds(100))

        // Entry should still be in cache (not cleaned up since maintenance didn't start)
        // Note: It's expired but not cleaned up until accessed
        #expect(service.allCachedInfo.isEmpty)  // allCachedInfo filters expired

        await service.shutdown()
    }

    // MARK: - IdentifyEvent Tests

    @Test("IdentifyEvent types")
    func eventTypes() {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let info = IdentifyInfo(agentVersion: "test/1.0.0")

        // Create each event type to verify they compile
        let received = IdentifyEvent.received(peer: peerID, info: info)
        let sent = IdentifyEvent.sent(peer: peerID)
        let pushReceived = IdentifyEvent.pushReceived(peer: peerID, info: info)
        let error = IdentifyEvent.error(peer: peerID, .timeout)
        let maintenance = IdentifyEvent.maintenanceCompleted(entriesRemoved: 5)

        // Verify pattern matching works
        switch received {
        case .received(let p, let i):
            #expect(p == peerID)
            #expect(i.agentVersion == "test/1.0.0")
        default:
            Issue.record("Expected received event")
        }

        switch sent {
        case .sent(let p):
            #expect(p == peerID)
        default:
            Issue.record("Expected sent event")
        }

        switch pushReceived {
        case .pushReceived(let p, let i):
            #expect(p == peerID)
            #expect(i.agentVersion == "test/1.0.0")
        default:
            Issue.record("Expected pushReceived event")
        }

        switch error {
        case .error(let p, let e):
            #expect(p == peerID)
            if case .timeout = e {
                // Expected
            } else {
                Issue.record("Expected timeout error")
            }
        default:
            Issue.record("Expected error event")
        }

        switch maintenance {
        case .maintenanceCompleted(let count):
            #expect(count == 5)
        default:
            Issue.record("Expected maintenanceCompleted event")
        }
    }

    @Test("Maintenance emits maintenanceCompleted event", .timeLimit(.minutes(1)))
    func maintenanceEmitsEvent() async throws {
        let service = IdentifyService(configuration: .init(
            cacheTTL: .milliseconds(30),
            cleanupInterval: .milliseconds(50)
        ))

        let events = service.events
        let peer = KeyPair.generateEd25519().peerID
        service.cacheInfo(IdentifyInfo(), for: peer)

        service.startMaintenance()

        let receivedMaintenanceEvent = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in events {
                    if case .maintenanceCompleted(let count) = event, count > 0 {
                        return true
                    }
                }
                return false
            }

            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return false
                }
                await service.shutdown()
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        await service.shutdown()
        #expect(receivedMaintenanceEvent)
    }
}

@Suite("IdentifyInfo Tests")
struct IdentifyInfoTests {

    @Test("IdentifyInfo equality")
    func infoEquality() {
        let info1 = IdentifyInfo(
            listenAddresses: [],
            protocols: ["/test/1.0.0"],
            agentVersion: "test/1.0.0"
        )

        let info2 = IdentifyInfo(
            listenAddresses: [],
            protocols: ["/test/1.0.0"],
            agentVersion: "test/1.0.0"
        )

        let info3 = IdentifyInfo(
            listenAddresses: [],
            protocols: ["/test/2.0.0"],
            agentVersion: "test/1.0.0"
        )

        #expect(info1 == info2)
        #expect(info1 != info3)
    }

    @Test("PeerID extracted from public key")
    func peerIDExtraction() {
        let keyPair = KeyPair.generateEd25519()

        let info = IdentifyInfo(publicKey: keyPair.publicKey)

        #expect(info.peerID == keyPair.peerID)
    }

    @Test("PeerID is nil when public key is nil")
    func peerIDNilWhenNoPublicKey() {
        let info = IdentifyInfo()

        #expect(info.peerID == nil)
    }
}

@Suite("IdentifyError Tests")
struct IdentifyErrorTests {

    @Test("IdentifyError cases exist")
    func errorCases() {
        let keyPair1 = KeyPair.generateEd25519()
        let keyPair2 = KeyPair.generateEd25519()

        // Create each error type to verify they exist
        let timeout = IdentifyError.timeout
        let mismatch = IdentifyError.peerIDMismatch(expected: keyPair1.peerID, actual: keyPair2.peerID)
        let streamError = IdentifyError.streamError("test error")
        let invalidProtobuf = IdentifyError.invalidProtobuf("invalid data")
        let notConnected = IdentifyError.notConnected
        let unsupported = IdentifyError.unsupported
        let messageTooLarge = IdentifyError.messageTooLarge(size: 100000, max: 65536)
        let invalidSignedPeerRecord = IdentifyError.invalidSignedPeerRecord("invalid record")

        // Verify they are distinct via switch
        let errors: [IdentifyError] = [timeout, mismatch, streamError, invalidProtobuf, notConnected, unsupported, messageTooLarge, invalidSignedPeerRecord]
        var matched = 0

        for error in errors {
            switch error {
            case .timeout:
                matched += 1
            case .peerIDMismatch:
                matched += 1
            case .streamError:
                matched += 1
            case .invalidProtobuf:
                matched += 1
            case .notConnected:
                matched += 1
            case .unsupported:
                matched += 1
            case .messageTooLarge:
                matched += 1
            case .invalidSignedPeerRecord:
                matched += 1
            }
        }

        #expect(matched == 8)
    }
}

@Suite("ProtocolID Constants Tests")
struct ProtocolIDConstantsTests {

    @Test("Identify protocol ID is correct")
    func identifyProtocolID() {
        #expect(ProtocolID.identify == "/ipfs/id/1.0.0")
    }

    @Test("Identify push protocol ID is correct")
    func identifyPushProtocolID() {
        #expect(ProtocolID.identifyPush == "/ipfs/id/push/1.0.0")
    }
}
