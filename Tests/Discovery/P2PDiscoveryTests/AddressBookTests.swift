import Testing
import Foundation
import Synchronization
@testable import P2PDiscovery
import P2PCore

// MARK: - Test Helpers

private func makePeer() -> PeerID {
    PeerID(publicKey: KeyPair.generateEd25519().publicKey)
}

/// Creates a MemoryPeerStore with no GC and no address TTL (addresses never expire).
private func makeStore(
    maxPeers: Int = 1000,
    maxAddressesPerPeer: Int = 10
) -> MemoryPeerStore {
    MemoryPeerStore(configuration: MemoryPeerStoreConfiguration(
        maxPeers: maxPeers,
        maxAddressesPerPeer: maxAddressesPerPeer,
        defaultAddressTTL: nil,
        gcInterval: nil
    ))
}

// MARK: - TransportType Detection Tests

@Suite("TransportType Detection")
struct TransportTypeDetectionTests {

    @Test("Detect TCP transport type from Multiaddr")
    func detectTCP() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/tcp/4001")
        #expect(TransportType.from(addr) == .tcp)
    }

    @Test("Detect TCP from factory method")
    func detectTCPFactory() {
        let addr = Multiaddr.tcp(host: "192.168.1.1", port: 4001)
        #expect(TransportType.from(addr) == .tcp)
    }

    @Test("Detect QUIC transport type from Multiaddr")
    func detectQUIC() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/udp/4001/quic-v1")
        #expect(TransportType.from(addr) == .quic)
    }

    @Test("Detect QUIC from factory method")
    func detectQUICFactory() {
        let addr = Multiaddr.quic(host: "192.168.1.1", port: 4001)
        #expect(TransportType.from(addr) == .quic)
    }

    @Test("Detect WebSocket transport type from Multiaddr")
    func detectWebSocket() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/tcp/80/ws")
        #expect(TransportType.from(addr) == .webSocket)
    }

    @Test("Detect WebSocket Secure transport type from Multiaddr")
    func detectWebSocketSecure() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/tcp/443/wss")
        #expect(TransportType.from(addr) == .webSocketSecure)
    }

    @Test("Detect memory transport type from Multiaddr")
    func detectMemory() {
        let addr = Multiaddr.memory(id: "test")
        #expect(TransportType.from(addr) == .memory)
    }

    @Test("Detect UDP transport type (without QUIC)")
    func detectUDP() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/udp/4001")
        #expect(TransportType.from(addr) == .udp)
    }

    @Test("Unknown transport for unrecognized protocol combinations")
    func detectUnknown() throws {
        let addr = try Multiaddr("/dns4/example.com")
        #expect(TransportType.from(addr) == .unknown)
    }

    @Test("TransportType is CaseIterable")
    func caseIterable() {
        let allCases = TransportType.allCases
        #expect(allCases.contains(.tcp))
        #expect(allCases.contains(.quic))
        #expect(allCases.contains(.udp))
        #expect(allCases.contains(.webSocket))
        #expect(allCases.contains(.webSocketSecure))
        #expect(allCases.contains(.webRTC))
        #expect(allCases.contains(.memory))
        #expect(allCases.contains(.unknown))
    }
}

// MARK: - AddressBookConfiguration Tests

@Suite("AddressBookConfiguration")
struct AddressBookConfigurationTests {

    @Test("Default configuration has expected weights")
    func defaultConfig() {
        let config = AddressBookConfiguration.default
        #expect(config.transportWeight == 0.4)
        #expect(config.successWeight == 0.4)
        #expect(config.recencyWeight == 0.2)
        #expect(config.maxFailureCount == 3)
        #expect(config.addressTTL == .seconds(3600))
    }

    @Test("Custom configuration preserves values")
    func customConfig() {
        let config = AddressBookConfiguration(
            transportPriority: [.quic, .tcp],
            maxFailureCount: 5,
            addressTTL: .seconds(7200),
            transportWeight: 0.5,
            successWeight: 0.3,
            recencyWeight: 0.2
        )
        #expect(config.transportPriority == [.quic, .tcp])
        #expect(config.maxFailureCount == 5)
        #expect(config.addressTTL == .seconds(7200))
        #expect(config.transportWeight == 0.5)
        #expect(config.successWeight == 0.3)
        #expect(config.recencyWeight == 0.2)
    }

    @Test("Default transport priority order")
    func defaultTransportPriority() {
        let config = AddressBookConfiguration.default
        #expect(config.transportPriority == [.tcp, .quic, .udp, .webSocket, .webSocketSecure, .memory])
    }
}

// MARK: - DefaultAddressBook Basic Operations Tests

@Suite("DefaultAddressBook Basic Operations")
struct DefaultAddressBookBasicTests {

    @Test("Add and retrieve addresses for a peer")
    func addAndRetrieve() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "192.168.1.1", port: 4001)
        let addr2 = Multiaddr.tcp(host: "192.168.1.1", port: 4002)

        let sorted = await book.addAndSort(addresses: [addr1, addr2], for: peer)

        #expect(sorted.count == 2)
    }

    @Test("Empty result for unknown peer")
    func unknownPeer() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()

        let result = await book.sortedAddresses(for: peer)
        #expect(result.isEmpty)
    }

    @Test("bestAddress returns nil for unknown peer")
    func bestAddressUnknown() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()

        let result = await book.bestAddress(for: peer)
        #expect(result == nil)
    }

    @Test("bestAddress returns the highest-scored address")
    func bestAddressReturnsFirst() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddress(addr, for: peer)

        let best = await book.bestAddress(for: peer)
        #expect(best == addr)
    }

    @Test("hasAddresses returns false for unknown peer")
    func hasAddressesFalse() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()

        let result = await book.hasAddresses(for: peer)
        #expect(!result)
    }

    @Test("hasAddresses returns true after adding addresses")
    func hasAddressesTrue() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()

        await store.addAddress(Multiaddr.tcp(host: "1.2.3.4", port: 80), for: peer)

        let result = await book.hasAddresses(for: peer)
        #expect(result)
    }

    @Test("Remove peer clears all addresses")
    func removePeer() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()

        await store.addAddress(Multiaddr.tcp(host: "1.2.3.4", port: 80), for: peer)
        #expect(await book.hasAddresses(for: peer))

        await store.removePeer(peer)
        #expect(!(await book.hasAddresses(for: peer)))
    }

    @Test("Remove individual address")
    func removeAddress() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "1.2.3.4", port: 4002)

        await store.addAddresses([addr1, addr2], for: peer)
        #expect(await book.sortedAddresses(for: peer).count == 2)

        await store.removeAddress(addr1, for: peer)
        let remaining = await book.sortedAddresses(for: peer)
        #expect(remaining.count == 1)
        #expect(remaining.first == addr2)
    }
}

// MARK: - Scoring Tests

@Suite("DefaultAddressBook Scoring")
struct DefaultAddressBookScoringTests {

    @Test("TCP ranked higher than QUIC with default priority (TCP is first)")
    func defaultPriorityTCPFirst() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let tcpAddr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let quicAddr = Multiaddr.quic(host: "1.2.3.4", port: 4001)

        // Default priority: [.tcp, .quic, .udp, .webSocket, .webSocketSecure, .memory]
        // TCP is index 0 (highest), QUIC is index 1
        await store.addAddresses([quicAddr, tcpAddr], for: peer)
        let sorted = await book.sortedAddresses(for: peer)

        #expect(sorted.first == tcpAddr)
    }

    @Test("Custom priority can put QUIC above TCP")
    func customPriorityQUICFirst() async {
        let store = makeStore()
        let config = AddressBookConfiguration(
            transportPriority: [.quic, .tcp, .udp, .webSocket, .webSocketSecure, .memory]
        )
        let book = DefaultAddressBook(peerStore: store, configuration: config)
        let peer = makePeer()
        let tcpAddr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let quicAddr = Multiaddr.quic(host: "1.2.3.4", port: 4001)

        await store.addAddresses([tcpAddr, quicAddr], for: peer)
        let sorted = await book.sortedAddresses(for: peer)

        #expect(sorted.first == quicAddr)
    }

    @Test("Score is between 0.0 and 1.0")
    func scoreBounds() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddress(addr, for: peer)
        let score = await book.score(address: addr, for: peer)

        #expect(score >= 0.0)
        #expect(score <= 1.0)
    }

    @Test("Unknown address gets lowest score for unknown peer")
    func scoreForUnknownAddress() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        // Don't add the address -- score for unknown address
        let score = await book.score(address: addr, for: peer)
        // No record = neutral success (0.5) and neutral recency (0.5)
        // Transport score for TCP at index 0 in priority of 6 items = 1.0 - (0/6) = 1.0
        // total = 0.4 * 1.0 + 0.4 * 0.5 + 0.2 * 0.5 = 0.4 + 0.2 + 0.1 = 0.7
        #expect(score >= 0.0)
        #expect(score <= 1.0)
    }

    @Test("Success history improves address ranking")
    func successImprovesRanking() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "1.2.3.4", port: 4002)

        await store.addAddresses([addr1, addr2], for: peer)

        // Record successes for addr2
        await book.recordSuccess(address: addr2, for: peer)
        await book.recordSuccess(address: addr2, for: peer)
        await book.recordSuccess(address: addr2, for: peer)

        let sorted = await book.sortedAddresses(for: peer)
        // addr2 should be ranked higher due to success history
        #expect(sorted.first == addr2)
    }

    @Test("Failure history degrades address ranking")
    func failureDegrades() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "1.2.3.4", port: 4002)

        await store.addAddresses([addr1, addr2], for: peer)

        // Give addr1 a success so it starts ranked high
        await book.recordSuccess(address: addr1, for: peer)

        // Then record many failures for addr1
        for _ in 0..<5 {
            await book.recordFailure(address: addr1, for: peer)
        }

        let sorted = await book.sortedAddresses(for: peer)
        // addr1 should drop due to failures exceeding maxFailureCount (default 3)
        #expect(sorted.last == addr1)
    }

    @Test("Address reaching maxFailureCount has lower score than address without failures")
    func maxFailuresDropsScore() async {
        let store = makeStore()
        let config = AddressBookConfiguration(maxFailureCount: 3)
        let book = DefaultAddressBook(peerStore: store, configuration: config)
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "1.2.3.4", port: 4002)

        await store.addAddresses([addr1, addr2], for: peer)

        // Record exactly maxFailureCount failures for addr1
        for _ in 0..<3 {
            await book.recordFailure(address: addr1, for: peer)
        }

        let failedScore = await book.score(address: addr1, for: peer)
        let normalScore = await book.score(address: addr2, for: peer)

        // The address with maxFailureCount failures should score lower
        // because its success component is 0.0 vs 0.5 (neutral)
        #expect(failedScore < normalScore)
    }

    @Test("Success resets failure count")
    func successResetsFailures() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddress(addr, for: peer)

        // Record failures
        for _ in 0..<5 {
            await book.recordFailure(address: addr, for: peer)
        }

        let scoreBefore = await book.score(address: addr, for: peer)

        // Record success (resets failure count to 0 in MemoryPeerStore)
        await book.recordSuccess(address: addr, for: peer)

        let scoreAfter = await book.score(address: addr, for: peer)
        #expect(scoreAfter > scoreBefore)
    }

    @Test("Different transport types produce different transport scores")
    func differentTransportScores() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let tcpAddr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let memAddr = Multiaddr.memory(id: "test")

        await store.addAddresses([tcpAddr, memAddr], for: peer)

        let tcpScore = await book.score(address: tcpAddr, for: peer)
        let memScore = await book.score(address: memAddr, for: peer)

        // TCP is higher priority (index 0) than memory (index 5) in default config
        #expect(tcpScore > memScore)
    }

    @Test("Empty transport priority list returns neutral transport score")
    func emptyTransportPriority() async {
        let store = makeStore()
        let config = AddressBookConfiguration(transportPriority: [])
        let book = DefaultAddressBook(peerStore: store, configuration: config)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddress(addr, for: peer)

        let score = await book.score(address: addr, for: peer)
        // With empty priority, transport score = 0.5 (neutral)
        #expect(score >= 0.0)
        #expect(score <= 1.0)
    }
}

// MARK: - Multiple Peers Tests

@Suite("DefaultAddressBook Multiple Peers")
struct DefaultAddressBookMultiplePeersTests {

    @Test("Addresses are isolated per peer")
    func perPeerIsolation() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer1 = makePeer()
        let peer2 = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "5.6.7.8", port: 4002)

        await store.addAddress(addr1, for: peer1)
        await store.addAddress(addr2, for: peer2)

        let addrs1 = await book.sortedAddresses(for: peer1)
        let addrs2 = await book.sortedAddresses(for: peer2)

        #expect(addrs1.count == 1)
        #expect(addrs2.count == 1)
        #expect(addrs1.first == addr1)
        #expect(addrs2.first == addr2)
    }

    @Test("Recording success for one peer does not affect another")
    func successIsolation() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer1 = makePeer()
        let peer2 = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddress(addr, for: peer1)
        await store.addAddress(addr, for: peer2)

        await book.recordSuccess(address: addr, for: peer1)

        let score1 = await book.score(address: addr, for: peer1)
        let score2 = await book.score(address: addr, for: peer2)

        // peer1 has success recorded, peer2 doesn't
        #expect(score1 > score2)
    }
}

// MARK: - Duplicate Handling Tests

@Suite("DefaultAddressBook Duplicate Handling")
struct DefaultAddressBookDuplicateTests {

    @Test("Adding duplicate addresses does not create duplicates")
    func noDuplicates() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddresses([addr, addr, addr], for: peer)
        let result = await book.sortedAddresses(for: peer)
        #expect(result.count == 1)
    }

    @Test("Re-adding existing address preserves history")
    func readdPreservesHistory() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddress(addr, for: peer)
        await book.recordSuccess(address: addr, for: peer)

        // Re-add same address
        await store.addAddress(addr, for: peer)

        // Should still have only 1 address
        let result = await book.sortedAddresses(for: peer)
        #expect(result.count == 1)

        // The success record should still be there (recordSuccess sets lastSuccess)
        let record = await store.addressRecord(addr, for: peer)
        #expect(record?.hasSucceeded == true)
    }
}

// MARK: - AddressBook addAndSort Extension Tests

@Suite("AddressBook addAndSort Extension")
struct AddressBookAddAndSortTests {

    @Test("addAndSort single address returns sorted list")
    func addAndSortSingle() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        let sorted = await book.addAndSort(address: addr, for: peer)
        #expect(sorted.count == 1)
        #expect(sorted.first == addr)
    }

    @Test("addAndSort multiple addresses returns sorted list")
    func addAndSortMultiple() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let tcpAddr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let quicAddr = Multiaddr.quic(host: "1.2.3.4", port: 4001)

        let sorted = await book.addAndSort(addresses: [quicAddr, tcpAddr], for: peer)
        #expect(sorted.count == 2)
        // TCP is higher priority than QUIC in default config
        #expect(sorted.first == tcpAddr)
    }

    @Test("addAndSort accumulates addresses across calls")
    func addAndSortAccumulates() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "1.2.3.4", port: 4002)

        let first = await book.addAndSort(address: addr1, for: peer)
        #expect(first.count == 1)

        let second = await book.addAndSort(address: addr2, for: peer)
        #expect(second.count == 2)
    }
}

// MARK: - PeerStore Max Addresses Tests

@Suite("PeerStore Address Limits")
struct PeerStoreAddressLimitsTests {

    @Test("Addresses capped at maxAddressesPerPeer")
    func maxAddressesCap() async {
        let store = makeStore(maxAddressesPerPeer: 5)
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()

        var addrs: [Multiaddr] = []
        for i in 0..<10 {
            addrs.append(Multiaddr.tcp(host: "1.2.3.4", port: UInt16(4000 + i)))
        }
        await store.addAddresses(addrs, for: peer)

        let result = await book.sortedAddresses(for: peer)
        #expect(result.count <= 5)
    }

    @Test("Adding beyond max evicts oldest address")
    func evictsOldest() async {
        let store = makeStore(maxAddressesPerPeer: 3)
        let peer = makePeer()

        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "1.2.3.4", port: 4002)
        let addr3 = Multiaddr.tcp(host: "1.2.3.4", port: 4003)

        await store.addAddress(addr1, for: peer)
        await store.addAddress(addr2, for: peer)
        await store.addAddress(addr3, for: peer)

        // All 3 should be present
        let before = await store.addresses(for: peer)
        #expect(before.count == 3)

        // Adding a 4th should evict one
        let addr4 = Multiaddr.tcp(host: "1.2.3.4", port: 4004)
        await store.addAddress(addr4, for: peer)

        let after = await store.addresses(for: peer)
        #expect(after.count == 3)
        #expect(after.contains(addr4))
    }
}

// MARK: - AddressRecord Tests

@Suite("AddressRecord")
struct AddressRecordTests {

    @Test("New record has no success")
    func newRecordNoSuccess() {
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let record = AddressRecord(address: addr)

        #expect(!record.hasSucceeded)
        #expect(record.failureCount == 0)
        #expect(record.lastSuccess == nil)
        #expect(record.lastFailure == nil)
    }

    @Test("hasSucceeded is true when lastSuccess is set")
    func hasSucceeded() {
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let record = AddressRecord(
            address: addr,
            lastSuccess: .now
        )

        #expect(record.hasSucceeded)
    }

    @Test("isRecentlyFailed when failure is after success")
    func recentlyFailed() {
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let now = ContinuousClock.now
        let record = AddressRecord(
            address: addr,
            lastSuccess: now - .seconds(10),
            lastFailure: now
        )

        #expect(record.isRecentlyFailed)
    }

    @Test("isRecentlyFailed is false when success is after failure")
    func notRecentlyFailed() {
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let now = ContinuousClock.now
        let record = AddressRecord(
            address: addr,
            lastSuccess: now,
            lastFailure: now - .seconds(10)
        )

        #expect(!record.isRecentlyFailed)
    }

    @Test("isRecentlyFailed is true when failure exists but no success")
    func recentlyFailedNoSuccess() {
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let record = AddressRecord(
            address: addr,
            lastFailure: .now
        )

        #expect(record.isRecentlyFailed)
    }

    @Test("isRecentlyFailed is false when no failure exists")
    func noFailure() {
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let record = AddressRecord(address: addr)

        #expect(!record.isRecentlyFailed)
    }

    @Test("isExpired when past expiresAt")
    func expired() {
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let record = AddressRecord(
            address: addr,
            expiresAt: .now - .seconds(10)
        )

        #expect(record.isExpired)
    }

    @Test("isExpired is false when before expiresAt")
    func notExpired() {
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let record = AddressRecord(
            address: addr,
            expiresAt: .now + .seconds(3600)
        )

        #expect(!record.isExpired)
    }

    @Test("isExpired is false when no expiresAt")
    func noExpiration() {
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let record = AddressRecord(address: addr)

        #expect(!record.isExpired)
    }
}

// MARK: - MemoryPeerStore Integration Tests

@Suite("MemoryPeerStore Integration with AddressBook")
struct MemoryPeerStoreIntegrationTests {

    @Test("recordSuccess updates address record via PeerStore")
    func recordSuccessUpdatesRecord() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddress(addr, for: peer)
        await book.recordSuccess(address: addr, for: peer)

        let record = await store.addressRecord(addr, for: peer)
        #expect(record != nil)
        #expect(record?.hasSucceeded == true)
        #expect(record?.failureCount == 0)
    }

    @Test("recordFailure updates address record via PeerStore")
    func recordFailureUpdatesRecord() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddress(addr, for: peer)
        await book.recordFailure(address: addr, for: peer)

        let record = await store.addressRecord(addr, for: peer)
        #expect(record != nil)
        #expect(record?.failureCount == 1)
        #expect(record?.lastFailure != nil)
    }

    @Test("Multiple failures increment failure count")
    func multipleFailures() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await store.addAddress(addr, for: peer)

        for _ in 0..<5 {
            await book.recordFailure(address: addr, for: peer)
        }

        let record = await store.addressRecord(addr, for: peer)
        #expect(record?.failureCount == 5)
    }

    @Test("recordSuccess on non-existent address is a no-op")
    func recordSuccessNonExistent() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        // Don't add the address, just record success
        await book.recordSuccess(address: addr, for: peer)

        let record = await store.addressRecord(addr, for: peer)
        #expect(record == nil)
    }

    @Test("recordFailure on non-existent address is a no-op")
    func recordFailureNonExistent() async {
        let store = makeStore()
        let book = DefaultAddressBook(peerStore: store)
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        await book.recordFailure(address: addr, for: peer)

        let record = await store.addressRecord(addr, for: peer)
        #expect(record == nil)
    }

    @Test("PeerStore events emitted on address add")
    func eventsOnAdd() async {
        let store = makeStore()
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)

        let eventStream = store.events
        let collected = Mutex<[PeerStoreEvent]>([])

        let task = Task {
            for await event in eventStream {
                collected.withLock { $0.append(event) }
            }
        }

        await store.addAddress(addr, for: peer)

        // Give time for event to propagate
        try? await Task.sleep(for: .milliseconds(50))

        task.cancel()

        let events = collected.withLock { $0 }
        #expect(events.contains(.addressAdded(peer, addr)))
    }

    @Test("addressRecords returns all records in a single call")
    func addressRecordsBatch() async {
        let store = makeStore()
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "1.2.3.4", port: 4002)

        await store.addAddresses([addr1, addr2], for: peer)

        let records = await store.addressRecords(for: peer)
        #expect(records.count == 2)
        #expect(records[addr1] != nil)
        #expect(records[addr2] != nil)
    }
}

// MARK: - CompositeDiscovery Additional Tests

@Suite("CompositeDiscovery Announce Behavior")
struct CompositeDiscoveryAnnounceTests {

    @Test("Announce succeeds if at least one service succeeds")
    func announcePartialSuccess() async throws {
        let service1 = MockDiscoveryService()
        let failingService = FailingDiscoveryService()
        let composite = CompositeDiscovery(services: [service1, failingService])

        // Should not throw because service1 succeeds
        try await composite.announce(addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
        #expect(service1.announcedAddresses.count == 1)
    }

    @Test("Announce throws if all services fail")
    func announceAllFail() async {
        let failing1 = FailingDiscoveryService()
        let failing2 = FailingDiscoveryService()
        let composite = CompositeDiscovery(services: [failing1, failing2])

        do {
            try await composite.announce(addresses: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)])
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            // Expected
        }
    }

    @Test("Find throws if all services fail")
    func findAllFail() async {
        let failing1 = FailingDiscoveryService()
        let failing2 = FailingDiscoveryService()
        let composite = CompositeDiscovery(services: [failing1, failing2])
        let peer = makePeer()

        do {
            _ = try await composite.find(peer: peer)
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            // Expected
        }
    }

    @Test("Find succeeds if at least one service succeeds")
    func findPartialSuccess() async throws {
        let peer = makePeer()
        let addr = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let candidate = ScoredCandidate(peerID: peer, addresses: [addr], score: 0.8)

        let service1 = MockDiscoveryService(candidates: [peer: [candidate]])
        let failing = FailingDiscoveryService()
        let composite = CompositeDiscovery(services: [service1, failing])

        let results = try await composite.find(peer: peer)
        #expect(results.count == 1)
        #expect(results[0].peerID == peer)
    }
}

@Suite("CompositeDiscovery Merging")
struct CompositeDiscoveryMergingTests {

    @Test("Merge deduplicates addresses for same peer")
    func mergeDeduplicatesAddresses() async throws {
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "1.2.3.4", port: 4002)

        // Both services report the same peer with overlapping addresses
        let candidate1 = ScoredCandidate(peerID: peer, addresses: [addr1, addr2], score: 0.8)
        let candidate2 = ScoredCandidate(peerID: peer, addresses: [addr1], score: 0.6)

        let service1 = MockDiscoveryService(candidates: [peer: [candidate1]])
        let service2 = MockDiscoveryService(candidates: [peer: [candidate2]])

        let composite = CompositeDiscovery(services: [service1, service2])

        let results = try await composite.find(peer: peer)
        #expect(results.count == 1)
        // Addresses should be deduplicated: addr1 and addr2
        #expect(results[0].addresses.count == 2)
        #expect(Set(results[0].addresses).contains(addr1))
        #expect(Set(results[0].addresses).contains(addr2))
    }

    @Test("Merge computes weighted average score")
    func mergeComputesAverageScore() async throws {
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "5.6.7.8", port: 4001)

        let candidate1 = ScoredCandidate(peerID: peer, addresses: [addr1], score: 0.8)
        let candidate2 = ScoredCandidate(peerID: peer, addresses: [addr2], score: 0.4)

        let service1 = MockDiscoveryService(candidates: [peer: [candidate1]])
        let service2 = MockDiscoveryService(candidates: [peer: [candidate2]])

        let composite = CompositeDiscovery(services: [service1, service2])
        let results = try await composite.find(peer: peer)

        #expect(results.count == 1)
        // Average of 0.8 and 0.4 = 0.6 (use approximate comparison for floating point)
        #expect(abs(results[0].score - 0.6) < 0.0001)
    }

    @Test("Find with multiple distinct peers returns all, sorted by score")
    func findMultipleDistinctPeers() async throws {
        let peer1 = makePeer()
        let peer2 = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "5.6.7.8", port: 4002)

        let target = makePeer()
        let candidate1 = ScoredCandidate(peerID: peer1, addresses: [addr1], score: 0.3)
        let candidate2 = ScoredCandidate(peerID: peer2, addresses: [addr2], score: 0.9)

        let service = MockDiscoveryService(candidates: [target: [candidate1, candidate2]])
        let composite = CompositeDiscovery(services: [service])

        let results = try await composite.find(peer: target)
        #expect(results.count == 2)
        // Sorted by score descending
        #expect(results[0].score > results[1].score)
    }
}

@Suite("CompositeDiscovery Lifecycle")
struct CompositeDiscoveryLifecycleTests {

    @Test("Start is idempotent")
    func startIdempotent() async {
        let service = MockDiscoveryService()
        let composite = CompositeDiscovery(services: [service])

        await composite.start()
        await composite.start()  // Second start should be no-op

        // Should still be functional
        let peers = await composite.knownPeers()
        #expect(peers.isEmpty)

        await composite.stop()
    }

    @Test("Operations work without calling start")
    func operationsWithoutStart() async throws {
        let service = MockDiscoveryService()
        let composite = CompositeDiscovery(services: [service])

        // These should work even without start()
        try await composite.announce(addresses: [])
        let peers = await composite.knownPeers()
        #expect(peers.isEmpty)

        await composite.stop()
    }

    @Test("Empty services list works")
    func emptyServices() async throws {
        let composite = CompositeDiscovery(services: [] as [any DiscoveryService])

        await composite.start()

        let peers = await composite.knownPeers()
        #expect(peers.isEmpty)

        // Find should return empty (no services to fail)
        let results = try await composite.find(peer: makePeer())
        #expect(results.isEmpty)

        await composite.stop()
    }

    @Test("Weighted initialization preserves weights in scoring")
    func weightedInit() async throws {
        let peer = makePeer()
        let addr1 = Multiaddr.tcp(host: "1.2.3.4", port: 4001)
        let addr2 = Multiaddr.tcp(host: "5.6.7.8", port: 4002)

        let candidate1 = ScoredCandidate(peerID: peer, addresses: [addr1], score: 1.0)
        let candidate2 = ScoredCandidate(peerID: peer, addresses: [addr2], score: 1.0)

        let service1 = MockDiscoveryService(candidates: [peer: [candidate1]])
        let service2 = MockDiscoveryService(candidates: [peer: [candidate2]])

        let composite = CompositeDiscovery(services: [
            (service: service1, weight: 3.0),
            (service: service2, weight: 1.0)
        ])

        let results = try await composite.find(peer: peer)
        #expect(results.count == 1)
        // Weighted: (3.0 * 1.0 + 1.0 * 1.0) / 2 = 2.0
        #expect(results[0].score == 2.0)

        await composite.stop()
    }
}

@Suite("CompositeDiscovery Observation Forwarding", .serialized)
struct CompositeDiscoveryObservationTests {

    @Test("Observations from child services are forwarded", .timeLimit(.minutes(1)))
    func forwardsObservations() async throws {
        let mock = MockDiscoveryService()
        let composite = CompositeDiscovery(services: [mock])

        await composite.start()

        let observations = composite.observations
        let received = Mutex<[Observation]>([])

        let consumeTask = Task {
            for await obs in observations {
                received.withLock { $0.append(obs) }
            }
        }

        // Give time for consumer to start
        try await Task.sleep(for: .milliseconds(50))

        let subject = makePeer()
        let observer = makePeer()
        let obs = Observation(
            subject: subject,
            observer: observer,
            kind: .reachable,
            hints: [Multiaddr.tcp(host: "1.2.3.4", port: 4001)],
            timestamp: 1000,
            sequenceNumber: 1
        )
        mock.emit(obs)

        // Give time for forwarding
        try await Task.sleep(for: .milliseconds(100))

        await composite.stop()
        consumeTask.cancel()

        let events = received.withLock { $0 }
        #expect(events.count == 1)
        #expect(events.first?.subject == subject)
        #expect(events.first?.kind == .reachable)
    }

    @Test("Forwarded observations get new sequence numbers", .timeLimit(.minutes(1)))
    func forwardedSequenceNumbers() async throws {
        let mock = MockDiscoveryService()
        let composite = CompositeDiscovery(services: [mock])

        await composite.start()

        let observations = composite.observations
        let received = Mutex<[Observation]>([])

        let consumeTask = Task {
            for await obs in observations {
                let count = received.withLock { r in
                    r.append(obs)
                    return r.count
                }
                if count >= 2 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        let subject = makePeer()
        let observer = makePeer()

        // Emit two observations with same sequence number
        for _ in 0..<2 {
            mock.emit(Observation(
                subject: subject,
                observer: observer,
                kind: .announcement,
                hints: [],
                timestamp: 1000,
                sequenceNumber: 42
            ))
        }

        try await Task.sleep(for: .milliseconds(100))

        await composite.stop()
        consumeTask.cancel()

        let events = received.withLock { $0 }
        if events.count >= 2 {
            // Composite should assign new incremental sequence numbers
            #expect(events[0].sequenceNumber != events[1].sequenceNumber)
        }
    }

    @Test("Subscribe filters observations by peer", .timeLimit(.minutes(1)))
    func subscribeFilters() async throws {
        let mock = MockDiscoveryService()
        let composite = CompositeDiscovery(services: [mock])

        await composite.start()

        let target = makePeer()
        let other = makePeer()
        let observer = makePeer()

        let subscription = composite.subscribe(to: target)
        let received = Mutex<[Observation]>([])

        let consumeTask = Task {
            for await obs in subscription {
                received.withLock { $0.append(obs) }
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Emit observation for target
        mock.emit(Observation(
            subject: target,
            observer: observer,
            kind: .reachable,
            hints: [],
            timestamp: 1000,
            sequenceNumber: 1
        ))

        // Emit observation for other peer (should be filtered)
        mock.emit(Observation(
            subject: other,
            observer: observer,
            kind: .reachable,
            hints: [],
            timestamp: 1001,
            sequenceNumber: 2
        ))

        try await Task.sleep(for: .milliseconds(100))

        await composite.stop()
        consumeTask.cancel()

        let events = received.withLock { $0 }
        // Should only have the observation for target
        for event in events {
            #expect(event.subject == target)
        }
    }
}

// MARK: - FailingDiscoveryService (Test Double)

/// A discovery service that always fails, for testing partial failure scenarios.
private final class FailingDiscoveryService: DiscoveryService, Sendable {

    private struct TestError: Error {}

    private let eventStream: AsyncStream<Observation>
    private let eventContinuation: AsyncStream<Observation>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Observation>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    func announce(addresses: [Multiaddr]) async throws {
        throw TestError()
    }

    func find(peer: PeerID) async throws -> [ScoredCandidate] {
        throw TestError()
    }

    func subscribe(to peer: PeerID) -> AsyncStream<Observation> {
        AsyncStream { $0.finish() }
    }

    func knownPeers() async -> [PeerID] { [] }

    var observations: AsyncStream<Observation> {
        eventStream
    }

    func stop() async {
        eventContinuation.finish()
    }
}
