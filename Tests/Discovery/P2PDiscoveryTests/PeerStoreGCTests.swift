import Testing
import Foundation
@testable import P2PDiscovery
@testable import P2PCore

// MARK: - PeerStore GC Tests

@Suite("PeerStore GC Tests")
struct PeerStoreGCTests {

    @Test("AddressRecord isExpired returns true when expiresAt is in the past")
    func addressRecordExpired() {
        let record = AddressRecord(
            address: try! Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            expiresAt: ContinuousClock.now - .seconds(1)
        )
        #expect(record.isExpired)
    }

    @Test("AddressRecord isExpired returns false when expiresAt is nil")
    func addressRecordNeverExpires() {
        let record = AddressRecord(
            address: try! Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            expiresAt: nil
        )
        #expect(!record.isExpired)
    }

    @Test("AddressRecord isExpired returns false when expiresAt is in the future")
    func addressRecordNotYetExpired() {
        let record = AddressRecord(
            address: try! Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            expiresAt: ContinuousClock.now + .seconds(3600)
        )
        #expect(!record.isExpired)
    }

    @Test("addAddresses with TTL sets expiresAt")
    func addAddressesWithTTL() async {
        let store = MemoryPeerStore(configuration: .init(
            defaultAddressTTL: nil,  // No default — only explicit TTL should apply
            gcInterval: nil
        ))
        let peer = KeyPair.generateEd25519().peerID
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")

        await store.addAddresses([addr], for: peer, ttl: .seconds(60))

        let record = await store.addressRecord(addr, for: peer)
        #expect(record != nil)
        #expect(record?.expiresAt != nil)
        #expect(!record!.isExpired)
    }

    @Test("addAddresses with nil TTL and nil default results in no expiration")
    func addAddressesWithoutTTL() async {
        let store = MemoryPeerStore(configuration: .init(
            defaultAddressTTL: nil,
            gcInterval: nil
        ))
        let peer = KeyPair.generateEd25519().peerID
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")

        await store.addAddresses([addr], for: peer, ttl: nil)

        let record = await store.addressRecord(addr, for: peer)
        #expect(record != nil)
        #expect(record?.expiresAt == nil)
    }

    @Test("addAddresses extends TTL when new expiration is later")
    func extendsTTL() async {
        let store = MemoryPeerStore(configuration: .init(
            defaultAddressTTL: nil,
            gcInterval: nil
        ))
        let peer = KeyPair.generateEd25519().peerID
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")

        // Add with short TTL
        await store.addAddresses([addr], for: peer, ttl: .seconds(60))
        let firstRecord = await store.addressRecord(addr, for: peer)
        let firstExpiry = firstRecord?.expiresAt

        // Re-add with longer TTL — should extend
        await store.addAddresses([addr], for: peer, ttl: .seconds(3600))
        let secondRecord = await store.addressRecord(addr, for: peer)
        let secondExpiry = secondRecord?.expiresAt

        #expect(firstExpiry != nil)
        #expect(secondExpiry != nil)
        #expect(secondExpiry! > firstExpiry!)
    }

    @Test("addAddresses does not shorten TTL when new expiration is earlier")
    func doesNotShortenTTL() async {
        let store = MemoryPeerStore(configuration: .init(
            defaultAddressTTL: nil,
            gcInterval: nil
        ))
        let peer = KeyPair.generateEd25519().peerID
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")

        // Add with long TTL
        await store.addAddresses([addr], for: peer, ttl: .seconds(3600))
        let firstRecord = await store.addressRecord(addr, for: peer)
        let firstExpiry = firstRecord?.expiresAt

        // Re-add with shorter TTL — should NOT shorten
        await store.addAddresses([addr], for: peer, ttl: .seconds(60))
        let secondRecord = await store.addressRecord(addr, for: peer)
        let secondExpiry = secondRecord?.expiresAt

        #expect(firstExpiry != nil)
        #expect(secondExpiry != nil)
        #expect(secondExpiry! >= firstExpiry!)
    }

    @Test("addresses(for:) filters expired addresses")
    func addressesFiltersExpired() async {
        let store = MemoryPeerStore(configuration: .init(
            defaultAddressTTL: nil,
            gcInterval: nil
        ))
        let peer = KeyPair.generateEd25519().peerID
        let validAddr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let expiringAddr = try! Multiaddr("/ip4/127.0.0.1/tcp/4002")

        // Add permanent address
        await store.addAddresses([validAddr], for: peer, ttl: nil)
        // Add address with very short TTL
        await store.addAddresses([expiringAddr], for: peer, ttl: .milliseconds(1))

        // Wait for expiration
        do { try await Task.sleep(for: .milliseconds(10)) } catch { }

        let addresses = await store.addresses(for: peer)
        #expect(addresses.count == 1)
        #expect(addresses.contains(validAddr))
        #expect(!addresses.contains(expiringAddr))
    }

    @Test("cleanup removes expired addresses and returns count")
    func cleanupRemovesExpired() async {
        let store = MemoryPeerStore(configuration: .init(
            defaultAddressTTL: nil,
            gcInterval: nil
        ))
        let peer = KeyPair.generateEd25519().peerID
        let addr1 = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let addr2 = try! Multiaddr("/ip4/127.0.0.1/tcp/4002")

        // Add two addresses — one permanent, one already expired
        await store.addAddresses([addr1], for: peer, ttl: nil)
        await store.addAddresses([addr2], for: peer, ttl: .milliseconds(1))

        // Wait for expiration
        do { try await Task.sleep(for: .milliseconds(10)) } catch { }

        let removed = store.cleanup()
        #expect(removed == 1)

        // Permanent address should remain
        let record = await store.addressRecord(addr1, for: peer)
        #expect(record != nil)

        // Expired address should be gone
        let expiredRecord = await store.addressRecord(addr2, for: peer)
        #expect(expiredRecord == nil)
    }

    @Test("cleanup removes peer when all addresses expire")
    func cleanupRemovesPeerWhenEmpty() async {
        let store = MemoryPeerStore(configuration: .init(
            defaultAddressTTL: nil,
            gcInterval: nil
        ))
        let peer = KeyPair.generateEd25519().peerID
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")

        await store.addAddresses([addr], for: peer, ttl: .milliseconds(1))

        // Wait for expiration
        do { try await Task.sleep(for: .milliseconds(10)) } catch { }

        let removed = store.cleanup()
        #expect(removed == 1)

        // Peer should be completely removed
        let count = await store.peerCount()
        #expect(count == 0)
    }

    @Test("defaultAddressTTL is applied when ttl parameter is nil")
    func defaultTTLApplied() async {
        let store = MemoryPeerStore(configuration: .init(
            defaultAddressTTL: .seconds(300),
            gcInterval: nil
        ))
        let peer = KeyPair.generateEd25519().peerID
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")

        // Add without explicit TTL — should use default
        await store.addAddresses([addr], for: peer, ttl: nil)

        let record = await store.addressRecord(addr, for: peer)
        #expect(record != nil)
        #expect(record?.expiresAt != nil)
        #expect(!record!.isExpired)
    }

    @Test("addAddresses with nil TTL upgrades to permanent")
    func nilTTLUpgradesToPermanent() async {
        let store = MemoryPeerStore(configuration: .init(
            defaultAddressTTL: nil,
            gcInterval: nil
        ))
        let peer = KeyPair.generateEd25519().peerID
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")

        // Add with explicit TTL
        await store.addAddresses([addr], for: peer, ttl: .seconds(60))
        let firstRecord = await store.addressRecord(addr, for: peer)
        #expect(firstRecord?.expiresAt != nil)

        // Re-add with nil TTL (permanent) — should upgrade to permanent
        await store.addAddresses([addr], for: peer, ttl: nil)
        let secondRecord = await store.addressRecord(addr, for: peer)
        #expect(secondRecord?.expiresAt == nil)
    }
}
