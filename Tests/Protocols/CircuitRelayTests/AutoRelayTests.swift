/// AutoRelayTests - Tests for the AutoRelay service.

import Testing
import Foundation
import Synchronization
@testable import P2PCircuitRelay
@testable import P2PCore

// MARK: - Configuration Tests

@Suite("AutoRelay Configuration Tests")
struct AutoRelayConfigurationTests {

    @Test("Default configuration values")
    func testDefaultConfiguration() {
        let config = AutoRelayConfiguration()

        #expect(config.maxRelays == 3)
        #expect(config.refreshInterval == .seconds(300))
        #expect(config.reservationTimeout == .seconds(30))
    }

    @Test("Custom configuration values")
    func testCustomConfiguration() {
        let config = AutoRelayConfiguration(
            maxRelays: 5,
            refreshInterval: .seconds(600),
            reservationTimeout: .seconds(60)
        )

        #expect(config.maxRelays == 5)
        #expect(config.refreshInterval == .seconds(600))
        #expect(config.reservationTimeout == .seconds(60))
    }
}

// MARK: - Candidate Relay Management Tests

@Suite("AutoRelay Candidate Management Tests", .serialized)
struct AutoRelayCandidateTests {

    @Test("Adding candidate relays")
    func testAddCandidateRelay() {
        let localKey = KeyPair.generateEd25519()
        let relay1Key = KeyPair.generateEd25519()
        let relay2Key = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "5.6.7.8", port: 4001)

        autoRelay.addCandidateRelay(relay1Key.peerID, addresses: [addr1])
        autoRelay.addCandidateRelay(relay2Key.peerID, addresses: [addr2])

        // No active relays yet (no reservation cycle performed)
        #expect(autoRelay.activeRelayPeers().isEmpty)
        #expect(autoRelay.relayAddresses().isEmpty)

        autoRelay.shutdown()
    }

    @Test("Removing candidate relay")
    func testRemoveCandidateRelay() {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [addr])
        autoRelay.removeCandidateRelay(relayKey.peerID)

        // Still no active relays
        #expect(autoRelay.activeRelayPeers().isEmpty)

        autoRelay.shutdown()
    }

    @Test("Removing active relay emits events")
    func testRemoveActiveRelayEmitsEvents() async throws {
        let localKey = KeyPair.generateEd25519()
        let relay1Key = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        autoRelay.addCandidateRelay(relay1Key.peerID, addresses: [addr1])

        // Set reachability to private and perform reservation cycle
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()

        #expect(autoRelay.activeRelayPeers().count == 1)

        // Remove the active relay
        autoRelay.removeCandidateRelay(relay1Key.peerID)

        #expect(autoRelay.activeRelayPeers().isEmpty)
        #expect(autoRelay.relayAddresses().isEmpty)

        autoRelay.shutdown()
    }
}

// MARK: - Relay Selection Tests

@Suite("AutoRelay Relay Selection Tests", .serialized)
struct AutoRelaySelectionTests {

    @Test("Selects relays when private")
    func testSelectsRelaysWhenPrivate() async throws {
        let localKey = KeyPair.generateEd25519()
        let relay1Key = KeyPair.generateEd25519()
        let relay2Key = KeyPair.generateEd25519()
        let relay3Key = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        // Add 3 candidate relays
        autoRelay.addCandidateRelay(relay1Key.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.addCandidateRelay(relay2Key.peerID, addresses: [Multiaddr.tcp(host: "5.6.7.8", port: 4001)])
        autoRelay.addCandidateRelay(relay3Key.peerID, addresses: [Multiaddr.tcp(host: "9.10.11.12", port: 4001)])

        // Set reachability to private and perform cycle
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()

        // Should have selected up to maxRelays (3) relays
        let active = autoRelay.activeRelayPeers()
        #expect(active.count == 3)

        // Should have relay addresses
        let addresses = autoRelay.relayAddresses()
        #expect(addresses.count == 3)

        autoRelay.shutdown()
    }

    @Test("Respects maxRelays limit")
    func testRespectsMaxRelaysLimit() async throws {
        let localKey = KeyPair.generateEd25519()

        let config = AutoRelayConfiguration(maxRelays: 2)
        let autoRelay = AutoRelay(localPeer: localKey.peerID, configuration: config)

        // Add more candidates than maxRelays
        for i in 0..<5 {
            let key = KeyPair.generateEd25519()
            autoRelay.addCandidateRelay(key.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.\(i)", port: 4001)])
        }

        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()

        // Should not exceed maxRelays
        #expect(autoRelay.activeRelayPeers().count == 2)
        #expect(autoRelay.relayAddresses().count == 2)

        autoRelay.shutdown()
    }

    @Test("Does not select relays when publicly reachable")
    func testNoSelectionWhenPublic() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.updateReachability(.publiclyReachable)
        await autoRelay.performReservationCycle()

        #expect(autoRelay.activeRelayPeers().isEmpty)
        #expect(autoRelay.relayAddresses().isEmpty)

        autoRelay.shutdown()
    }

    @Test("Does not select relays when reachability is unknown")
    func testNoSelectionWhenUnknown() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        await autoRelay.performReservationCycle()

        #expect(autoRelay.activeRelayPeers().isEmpty)

        autoRelay.shutdown()
    }

    @Test("needsMoreRelays reflects state correctly")
    func testNeedsMoreRelays() async throws {
        let localKey = KeyPair.generateEd25519()
        let config = AutoRelayConfiguration(maxRelays: 1)
        let autoRelay = AutoRelay(localPeer: localKey.peerID, configuration: config)

        // Initially unknown reachability - doesn't need relays
        #expect(!autoRelay.needsMoreRelays)

        // Set to private - needs relays
        autoRelay.updateReachability(.privateOnly)
        #expect(autoRelay.needsMoreRelays)

        // Add candidate and perform cycle
        let relayKey = KeyPair.generateEd25519()
        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        await autoRelay.performReservationCycle()

        // Now at maxRelays - doesn't need more
        #expect(!autoRelay.needsMoreRelays)

        autoRelay.shutdown()
    }
}

// MARK: - Relay Address Generation Tests

@Suite("AutoRelay Address Generation Tests")
struct AutoRelayAddressTests {

    @Test("Generates correct p2p-circuit addresses")
    func testCircuitAddressGeneration() throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let relayAddr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let circuitAddresses = autoRelay.buildCircuitAddresses(
            relayPeer: relayKey.peerID,
            relayAddresses: [relayAddr]
        )

        #expect(circuitAddresses.count == 1)

        let addr = circuitAddresses[0]
        let desc = addr.description

        // Should contain the relay's address components
        #expect(desc.contains("ip4/1.2.3.4"))
        #expect(desc.contains("tcp/4001"))

        // Should contain /p2p/<relay>/p2p-circuit/p2p/<self>
        #expect(desc.contains("p2p/\(relayKey.peerID)"))
        #expect(desc.contains("p2p-circuit"))
        #expect(desc.contains("p2p/\(localKey.peerID)"))

        autoRelay.shutdown()
    }

    @Test("Skips addresses that already contain p2p-circuit")
    func testSkipsExistingCircuitAddresses() throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()
        let otherKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        // Create an address that already has p2p-circuit
        let circuitAddr = Multiaddr(uncheckedProtocols: [
            .ip4("1.2.3.4"),
            .tcp(4001),
            .p2p(otherKey.peerID),
            .p2pCircuit,
            .p2p(relayKey.peerID)
        ])

        let normalAddr = Multiaddr.tcp(host: "5.6.7.8", port: 4001)

        let result = autoRelay.buildCircuitAddresses(
            relayPeer: relayKey.peerID,
            relayAddresses: [circuitAddr, normalAddr]
        )

        // Only the normal address should produce a circuit address
        #expect(result.count == 1)
        #expect(result[0].description.contains("5.6.7.8"))

        autoRelay.shutdown()
    }

    @Test("Handles relay address that already contains relay peer ID")
    func testHandlesAddressWithExistingPeerID() throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        // Address already includes the relay's peer ID
        let addrWithPeer = Multiaddr(uncheckedProtocols: [
            .ip4("1.2.3.4"),
            .tcp(4001),
            .p2p(relayKey.peerID)
        ])

        let result = autoRelay.buildCircuitAddresses(
            relayPeer: relayKey.peerID,
            relayAddresses: [addrWithPeer]
        )

        #expect(result.count == 1)

        // Should NOT have duplicate /p2p/<relay> components
        let protocols = result[0].protocols
        let p2pCount = protocols.filter {
            if case .p2p = $0 { return true } else { return false }
        }.count

        // Should have exactly 2 p2p components: relay + self
        #expect(p2pCount == 2)

        autoRelay.shutdown()
    }

    @Test("Generates addresses for multiple relay addresses")
    func testMultipleRelayAddresses() throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let addrs = [
            Multiaddr.tcp(host: "1.2.3.4", port: 4001),
            Multiaddr.tcp(host: "5.6.7.8", port: 4002),
            Multiaddr.quic(host: "1.2.3.4", port: 4003)
        ]

        let result = autoRelay.buildCircuitAddresses(
            relayPeer: relayKey.peerID,
            relayAddresses: addrs
        )

        #expect(result.count == 3)

        // Each address should contain p2p-circuit
        for addr in result {
            #expect(addr.description.contains("p2p-circuit"))
            #expect(addr.description.contains("p2p/\(localKey.peerID)"))
        }

        autoRelay.shutdown()
    }
}

// MARK: - Reachability Transition Tests

@Suite("AutoRelay Reachability Transition Tests", .serialized)
struct AutoRelayReachabilityTests {

    @Test("Transition to private allows reservations")
    func testTransitionToPrivate() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])

        // Transition to private
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()

        #expect(autoRelay.activeRelayPeers().count == 1)
        #expect(autoRelay.activeRelayPeers().contains(relayKey.peerID))

        autoRelay.shutdown()
    }

    @Test("Transition to public clears active relays")
    func testTransitionToPublic() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])

        // First go private
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()
        #expect(autoRelay.activeRelayPeers().count == 1)

        // Then go public
        autoRelay.updateReachability(.publiclyReachable)

        // Active relays should be cleared
        #expect(autoRelay.activeRelayPeers().isEmpty)
        #expect(autoRelay.relayAddresses().isEmpty)

        autoRelay.shutdown()
    }

    @Test("Transition public -> private -> public")
    func testPublicPrivatePublicTransition() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])

        // Start public
        autoRelay.updateReachability(.publiclyReachable)
        #expect(autoRelay.activeRelayPeers().isEmpty)

        // Go private
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()
        #expect(autoRelay.activeRelayPeers().count == 1)

        // Go public again
        autoRelay.updateReachability(.publiclyReachable)
        #expect(autoRelay.activeRelayPeers().isEmpty)

        // Go private again
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()
        #expect(autoRelay.activeRelayPeers().count == 1)

        autoRelay.shutdown()
    }

    @Test("Same reachability update is no-op")
    func testSameReachabilityIsNoop() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])

        // Set to private
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()
        #expect(autoRelay.activeRelayPeers().count == 1)

        // Set to private again (no change)
        autoRelay.updateReachability(.privateOnly)
        // Should not clear relays
        #expect(autoRelay.activeRelayPeers().count == 1)

        autoRelay.shutdown()
    }

    @Test("currentReachability returns correct value")
    func testCurrentReachability() {
        let localKey = KeyPair.generateEd25519()
        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        #expect(autoRelay.currentReachability == .unknown)

        autoRelay.updateReachability(.privateOnly)
        #expect(autoRelay.currentReachability == .privateOnly)

        autoRelay.updateReachability(.publiclyReachable)
        #expect(autoRelay.currentReachability == .publiclyReachable)

        autoRelay.shutdown()
    }
}

// MARK: - Event Emission Tests

@Suite("AutoRelay Event Emission Tests", .serialized)
struct AutoRelayEventTests {

    @Test("Emits relayAdded when reservation succeeds", .timeLimit(.minutes(1)))
    func testEmitsRelayAdded() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        // Start listening for events before performing cycle
        let eventStream = autoRelay.events

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.updateReachability(.privateOnly)

        // Perform reservation cycle
        let cycleTask = Task {
            await autoRelay.performReservationCycle()
        }

        // Collect first event
        var receivedRelayAdded = false
        for await event in eventStream {
            if case .relayAdded(let peer, _) = event {
                #expect(peer == relayKey.peerID)
                receivedRelayAdded = true
                break
            }
        }

        await cycleTask.value

        #expect(receivedRelayAdded)

        autoRelay.shutdown()
    }

    @Test("Emits relayRemoved when relay is removed", .timeLimit(.minutes(1)))
    func testEmitsRelayRemoved() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        // Set up active relay
        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()

        #expect(autoRelay.activeRelayPeers().count == 1)

        // Start listening for removal event
        let eventStream = autoRelay.events

        // Remove the relay
        let removeTask = Task {
            autoRelay.removeCandidateRelay(relayKey.peerID)
        }

        var receivedRemoved = false
        for await event in eventStream {
            if case .relayRemoved(let peer) = event {
                #expect(peer == relayKey.peerID)
                receivedRemoved = true
                break
            }
        }

        await removeTask.value

        #expect(receivedRemoved)

        autoRelay.shutdown()
    }

    @Test("Emits relayAddressesUpdated with complete address list", .timeLimit(.minutes(1)))
    func testEmitsRelayAddressesUpdated() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let eventStream = autoRelay.events

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.updateReachability(.privateOnly)

        let cycleTask = Task {
            await autoRelay.performReservationCycle()
        }

        var receivedUpdate = false
        for await event in eventStream {
            if case .relayAddressesUpdated(let addresses) = event {
                #expect(!addresses.isEmpty)
                for addr in addresses {
                    #expect(addr.description.contains("p2p-circuit"))
                }
                receivedUpdate = true
                break
            }
        }

        await cycleTask.value

        #expect(receivedUpdate)

        autoRelay.shutdown()
    }

    @Test("Emits reservationFailed on reservation error", .timeLimit(.minutes(1)))
    func testEmitsReservationFailed() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let eventStream = autoRelay.events

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.updateReachability(.privateOnly)

        // Perform reservation with a failing action
        let cycleTask = Task {
            await autoRelay.performReservationCycle { _, _ in
                throw AutoRelayTestError.reservationDenied
            }
        }

        var receivedFailed = false
        for await event in eventStream {
            if case .reservationFailed(let peer, _) = event {
                #expect(peer == relayKey.peerID)
                receivedFailed = true
                break
            }
        }

        await cycleTask.value

        #expect(receivedFailed)

        autoRelay.shutdown()
    }

    @Test("Emits relayRemoved and empty addresses on transition to public", .timeLimit(.minutes(1)))
    func testEmitsOnTransitionToPublic() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()

        #expect(autoRelay.activeRelayPeers().count == 1)

        let eventStream = autoRelay.events

        // Transition to public
        let transitionTask = Task {
            autoRelay.updateReachability(.publiclyReachable)
        }

        var receivedRemoved = false
        var receivedEmptyAddresses = false
        for await event in eventStream {
            switch event {
            case .relayRemoved(let peer):
                #expect(peer == relayKey.peerID)
                receivedRemoved = true
            case .relayAddressesUpdated(let addresses):
                #expect(addresses.isEmpty)
                receivedEmptyAddresses = true
            default:
                break
            }
            if receivedRemoved && receivedEmptyAddresses { break }
        }

        await transitionTask.value

        #expect(receivedRemoved)
        #expect(receivedEmptyAddresses)

        autoRelay.shutdown()
    }
}

// MARK: - Shutdown Tests

@Suite("AutoRelay Shutdown Tests", .serialized)
struct AutoRelayShutdownTests {

    @Test("Shutdown clears all state")
    func testShutdownClearsState() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()

        #expect(autoRelay.activeRelayPeers().count == 1)

        // Shutdown
        autoRelay.shutdown()

        #expect(autoRelay.activeRelayPeers().isEmpty)
        #expect(autoRelay.relayAddresses().isEmpty)
    }

    @Test("Shutdown is idempotent")
    func testShutdownIdempotent() {
        let localKey = KeyPair.generateEd25519()
        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.shutdown()
        autoRelay.shutdown()
        autoRelay.shutdown()

        // Should not crash
        #expect(autoRelay.activeRelayPeers().isEmpty)
    }

    @Test("Shutdown terminates event stream", .timeLimit(.minutes(1)))
    func testShutdownTerminatesEventStream() async throws {
        let localKey = KeyPair.generateEd25519()
        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let eventStream = autoRelay.events

        // Shutdown after a small delay
        Task {
            try await Task.sleep(for: .milliseconds(50))
            autoRelay.shutdown()
        }

        // This loop should terminate when shutdown is called
        var count = 0
        for await _ in eventStream {
            count += 1
        }

        // Loop ended, meaning the stream finished
        #expect(count == 0)
    }

    @Test("No reservations after shutdown")
    func testNoReservationsAfterShutdown() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.shutdown()

        // Adding candidates and updating reachability should be no-ops after shutdown
        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.updateReachability(.privateOnly)
        await autoRelay.performReservationCycle()

        #expect(autoRelay.activeRelayPeers().isEmpty)
    }
}

// MARK: - Concurrent Safety Tests

@Suite("AutoRelay Concurrent Safety Tests", .serialized)
struct AutoRelayConcurrencyTests {

    @Test("Concurrent candidate additions are safe", .timeLimit(.minutes(1)))
    func testConcurrentCandidateAdditions() async throws {
        let localKey = KeyPair.generateEd25519()
        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.updateReachability(.privateOnly)

        // Add many candidates concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let key = KeyPair.generateEd25519()
                    autoRelay.addCandidateRelay(
                        key.peerID,
                        addresses: [Multiaddr.tcp(host: "1.2.3.\(i % 256)", port: UInt16(4000 + i))]
                    )
                }
            }
        }

        // Should not crash, and maxRelays should be respected after cycle
        await autoRelay.performReservationCycle()
        #expect(autoRelay.activeRelayPeers().count <= autoRelay.configuration.maxRelays)

        autoRelay.shutdown()
    }

    @Test("Concurrent reachability updates are safe", .timeLimit(.minutes(1)))
    func testConcurrentReachabilityUpdates() async throws {
        let localKey = KeyPair.generateEd25519()
        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let relayKey = KeyPair.generateEd25519()
        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])

        // Rapidly toggle reachability
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    if i % 2 == 0 {
                        autoRelay.updateReachability(.privateOnly)
                    } else {
                        autoRelay.updateReachability(.publiclyReachable)
                    }
                }
            }
        }

        // Should not crash
        autoRelay.shutdown()
    }

    @Test("Concurrent reservation cycles are safe", .timeLimit(.minutes(1)))
    func testConcurrentReservationCycles() async throws {
        let localKey = KeyPair.generateEd25519()
        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        for i in 0..<5 {
            let key = KeyPair.generateEd25519()
            autoRelay.addCandidateRelay(key.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.\(i)", port: 4001)])
        }

        autoRelay.updateReachability(.privateOnly)

        // Run multiple cycles concurrently
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await autoRelay.performReservationCycle()
                }
            }
        }

        // Should not crash, maxRelays respected
        #expect(autoRelay.activeRelayPeers().count <= autoRelay.configuration.maxRelays)

        autoRelay.shutdown()
    }
}

// MARK: - Reservation Cycle with Custom Action Tests

@Suite("AutoRelay Reservation Action Tests", .serialized)
struct AutoRelayReservationActionTests {

    @Test("Custom reserve action is called for each candidate")
    func testCustomReserveAction() async throws {
        let localKey = KeyPair.generateEd25519()
        let relay1Key = KeyPair.generateEd25519()
        let relay2Key = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "5.6.7.8", port: 4001)

        autoRelay.addCandidateRelay(relay1Key.peerID, addresses: [addr1])
        autoRelay.addCandidateRelay(relay2Key.peerID, addresses: [addr2])

        autoRelay.updateReachability(.privateOnly)

        let reservedPeers = Mutex<[PeerID]>([])

        await autoRelay.performReservationCycle { peer, addrs in
            reservedPeers.withLock { $0.append(peer) }
            return addrs
        }

        let peers = reservedPeers.withLock { $0 }
        #expect(peers.count == 2)
        #expect(autoRelay.activeRelayPeers().count == 2)

        autoRelay.shutdown()
    }

    @Test("Failed reservations do not add active relays")
    func testFailedReservationsNotAdded() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.updateReachability(.privateOnly)

        // All reservations fail
        await autoRelay.performReservationCycle { _, _ in
            throw AutoRelayTestError.reservationDenied
        }

        let active = autoRelay.activeRelayPeers()
        #expect(active.isEmpty, "Failed reservation should not add relay to active list")

        autoRelay.shutdown()
    }

    @Test("Mixed success and failure in reservation cycle")
    func testMixedSuccessAndFailure() async throws {
        let localKey = KeyPair.generateEd25519()
        let relay1Key = KeyPair.generateEd25519()
        let relay2Key = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        autoRelay.addCandidateRelay(relay1Key.peerID, addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        autoRelay.addCandidateRelay(relay2Key.peerID, addresses: [Multiaddr.tcp(host: "5.6.7.8", port: 4001)])

        autoRelay.updateReachability(.privateOnly)

        // Track which peers were called
        let calledPeers = Mutex<[PeerID]>([])
        let failPeer = relay2Key.peerID

        await autoRelay.performReservationCycle { peer, addrs in
            calledPeers.withLock { $0.append(peer) }
            if peer == failPeer {
                throw AutoRelayTestError.reservationDenied
            }
            return addrs
        }

        let called = calledPeers.withLock { $0 }
        #expect(called.count == 2, "Both candidates should be attempted")

        // At least 1 relay should be active (relay1 succeeds)
        let active = autoRelay.activeRelayPeers()
        #expect(active.count >= 1)
        #expect(!active.contains(failPeer), "Failed relay should not be active")

        autoRelay.shutdown()
    }

    @Test("Reserve action provides correct addresses")
    func testReserveActionAddresses() async throws {
        let localKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let autoRelay = AutoRelay(localPeer: localKey.peerID)

        let relayAddr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        autoRelay.addCandidateRelay(relayKey.peerID, addresses: [relayAddr])
        autoRelay.updateReachability(.privateOnly)

        // Return custom addresses from reserve action
        let customAddr = Multiaddr.tcp(host: "10.20.30.40", port: 5001)
        await autoRelay.performReservationCycle { _, _ in
            return [customAddr]
        }

        let addresses = autoRelay.relayAddresses()
        #expect(addresses.count == 1)
        #expect(addresses[0].description.contains("10.20.30.40"))
        #expect(addresses[0].description.contains("p2p-circuit"))

        autoRelay.shutdown()
    }
}

// MARK: - Test Helpers

enum AutoRelayTestError: Error {
    case reservationDenied
}
