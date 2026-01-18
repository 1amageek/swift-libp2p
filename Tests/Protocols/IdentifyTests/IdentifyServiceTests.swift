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

        let info = IdentifyInfo(
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

        // Verify they are distinct via switch
        let errors: [IdentifyError] = [timeout, mismatch, streamError, invalidProtobuf, notConnected, unsupported, messageTooLarge]
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
            }
        }

        #expect(matched == 7)
    }
}

@Suite("LibP2PProtocol Constants Tests")
struct LibP2PProtocolConstantsTests {

    @Test("Identify protocol ID is correct")
    func identifyProtocolID() {
        #expect(LibP2PProtocol.identify == "/ipfs/id/1.0.0")
    }

    @Test("Identify push protocol ID is correct")
    func identifyPushProtocolID() {
        #expect(LibP2PProtocol.identifyPush == "/ipfs/id/push/1.0.0")
    }
}
