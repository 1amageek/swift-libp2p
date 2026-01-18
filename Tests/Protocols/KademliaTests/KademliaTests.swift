/// KademliaTests - Tests for Kademlia DHT implementation.

import Testing
import Foundation
@testable import P2PKademlia
@testable import P2PCore

@Suite("Kademlia Tests")
struct KademliaTests {

    // MARK: - KademliaKey Tests

    @Suite("KademliaKey Tests")
    struct KademliaKeyTests {

        @Test("Create key from raw bytes")
        func createFromBytes() throws {
            let bytes = Data(repeating: 0x42, count: 32)
            let key = KademliaKey(bytes: bytes)
            #expect(key.bytes == bytes)
        }

        @Test("Create key by hashing data")
        func createByHashing() throws {
            let data = Data("hello world".utf8)
            let key = KademliaKey(hashing: data)
            #expect(key.bytes.count == 32)
        }

        @Test("Create key from peer ID")
        func createFromPeerID() throws {
            let keyPair = KeyPair.generateEd25519()
            let peerID = try PeerID(publicKey: keyPair.publicKey)
            let key = KademliaKey(from: peerID)
            #expect(key.bytes.count == 32)
        }

        @Test("XOR distance is symmetric")
        func distanceSymmetric() throws {
            let key1 = KademliaKey(hashing: Data("a".utf8))
            let key2 = KademliaKey(hashing: Data("b".utf8))
            let dist1 = key1.distance(to: key2)
            let dist2 = key2.distance(to: key1)
            #expect(dist1 == dist2)
        }

        @Test("Distance to self is zero")
        func distanceToSelf() throws {
            let key = KademliaKey(hashing: Data("test".utf8))
            let dist = key.distance(to: key)
            #expect(dist.leadingZeroBits == 256)
        }

        @Test("Leading zero bits calculation")
        func leadingZeroBits() throws {
            // All zeros
            let allZero = KademliaKey(bytes: Data(repeating: 0, count: 32))
            #expect(allZero.leadingZeroBits == 256)

            // First bit set
            var bytes = Data(repeating: 0, count: 32)
            bytes[0] = 0x80  // 10000000
            let firstBitSet = KademliaKey(bytes: bytes)
            #expect(firstBitSet.leadingZeroBits == 0)

            // 8 leading zeros (second byte has first bit set)
            bytes[0] = 0x00
            bytes[1] = 0x80
            let eightZeros = KademliaKey(bytes: bytes)
            #expect(eightZeros.leadingZeroBits == 8)
        }

        @Test("Bucket index calculation")
        func bucketIndex() throws {
            // Distance with 0 leading zeros -> bucket 255
            var bytes = Data(repeating: 0, count: 32)
            bytes[0] = 0x80
            let key1 = KademliaKey(bytes: bytes)
            #expect(key1.bucketIndex == 255)

            // Distance with 8 leading zeros -> bucket 247
            bytes[0] = 0x00
            bytes[1] = 0x80
            let key2 = KademliaKey(bytes: bytes)
            #expect(key2.bucketIndex == 247)

            // All zeros (same key) -> nil
            let allZero = KademliaKey(bytes: Data(repeating: 0, count: 32))
            #expect(allZero.bucketIndex == nil)
        }

        @Test("Key comparison")
        func keyComparison() throws {
            var bytes1 = Data(repeating: 0, count: 32)
            var bytes2 = Data(repeating: 0, count: 32)

            bytes1[0] = 0x01
            bytes2[0] = 0x02

            let key1 = KademliaKey(bytes: bytes1)
            let key2 = KademliaKey(bytes: bytes2)

            #expect(key1 < key2)
            #expect(!(key2 < key1))
        }

        @Test("isCloser comparison")
        func isCloser() throws {
            let target = KademliaKey(hashing: Data("target".utf8))
            let closer = KademliaKey(hashing: Data("closer".utf8))
            let farther = KademliaKey(hashing: Data("farther".utf8))

            let closerDist = closer.distance(to: target)
            let fartherDist = farther.distance(to: target)

            // One of them should be closer
            let closerIsActuallyCloser = closerDist < fartherDist
            #expect(closer.isCloser(to: target, than: farther) == closerIsActuallyCloser)
        }

        // MARK: - Validation Tests

        @Test("Validating initializer accepts 32 bytes")
        func validatingAccepts32Bytes() throws {
            let bytes = Data(repeating: 0x42, count: 32)
            let key = try KademliaKey(validating: bytes)
            #expect(key.bytes == bytes)
        }

        @Test("Validating initializer rejects short input")
        func validatingRejectsShortInput() {
            let shortBytes = Data(repeating: 0x42, count: 16)

            do {
                _ = try KademliaKey(validating: shortBytes)
                Issue.record("Expected invalidLength error")
            } catch let error as KademliaKeyError {
                guard case .invalidLength(let actual, let expected) = error else {
                    Issue.record("Expected invalidLength error, got \(error)")
                    return
                }
                #expect(actual == 16)
                #expect(expected == 32)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }

        @Test("Validating initializer rejects long input")
        func validatingRejectsLongInput() {
            let longBytes = Data(repeating: 0x42, count: 64)

            do {
                _ = try KademliaKey(validating: longBytes)
                Issue.record("Expected invalidLength error")
            } catch let error as KademliaKeyError {
                guard case .invalidLength(let actual, let expected) = error else {
                    Issue.record("Expected invalidLength error, got \(error)")
                    return
                }
                #expect(actual == 64)
                #expect(expected == 32)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }

        @Test("Validating initializer rejects empty input")
        func validatingRejectsEmptyInput() {
            let emptyBytes = Data()

            do {
                _ = try KademliaKey(validating: emptyBytes)
                Issue.record("Expected invalidLength error")
            } catch let error as KademliaKeyError {
                guard case .invalidLength(let actual, let expected) = error else {
                    Issue.record("Expected invalidLength error, got \(error)")
                    return
                }
                #expect(actual == 0)
                #expect(expected == 32)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }

        @Test("InvalidLength error is Equatable")
        func invalidLengthEquatable() {
            let error1 = KademliaKeyError.invalidLength(actual: 16, expected: 32)
            let error2 = KademliaKeyError.invalidLength(actual: 16, expected: 32)
            let error3 = KademliaKeyError.invalidLength(actual: 64, expected: 32)

            #expect(error1 == error2)
            #expect(error1 != error3)
        }
    }

    // MARK: - KBucket Tests

    @Suite("KBucket Tests")
    struct KBucketTests {

        @Test("Insert into empty bucket")
        func insertEmpty() throws {
            var bucket = KBucket(maxSize: 3)
            let keyPair = KeyPair.generateEd25519()
            let peerID = try PeerID(publicKey: keyPair.publicKey)

            let result = bucket.insert(peerID)
            #expect(result == .inserted)
            #expect(bucket.count == 1)
        }

        @Test("Update existing peer")
        func updateExisting() throws {
            var bucket = KBucket(maxSize: 3)
            let keyPair = KeyPair.generateEd25519()
            let peerID = try PeerID(publicKey: keyPair.publicKey)

            _ = bucket.insert(peerID)
            let result = bucket.insert(peerID)
            #expect(result == .updated)
            #expect(bucket.count == 1)
        }

        @Test("Bucket becomes full")
        func bucketFull() throws {
            var bucket = KBucket(maxSize: 2)

            let keyPair1 = KeyPair.generateEd25519()
            let keyPair2 = KeyPair.generateEd25519()
            let keyPair3 = KeyPair.generateEd25519()

            let peer1 = try PeerID(publicKey: keyPair1.publicKey)
            let peer2 = try PeerID(publicKey: keyPair2.publicKey)
            let peer3 = try PeerID(publicKey: keyPair3.publicKey)

            #expect(bucket.insert(peer1) == .inserted)
            #expect(bucket.insert(peer2) == .inserted)
            #expect(bucket.insert(peer3) == .pending)
            #expect(bucket.isFull)
        }

        @Test("Remove peer")
        func removePeer() throws {
            var bucket = KBucket(maxSize: 3)
            let keyPair = KeyPair.generateEd25519()
            let peerID = try PeerID(publicKey: keyPair.publicKey)

            _ = bucket.insert(peerID)
            let removed = bucket.remove(peerID)

            #expect(removed != nil)
            #expect(removed?.peerID == peerID)
            #expect(bucket.isEmpty)
        }

        @Test("Remove promotes from pending")
        func removePromotesPending() throws {
            var bucket = KBucket(maxSize: 2)

            let keyPair1 = KeyPair.generateEd25519()
            let keyPair2 = KeyPair.generateEd25519()
            let keyPair3 = KeyPair.generateEd25519()

            let peer1 = try PeerID(publicKey: keyPair1.publicKey)
            let peer2 = try PeerID(publicKey: keyPair2.publicKey)
            let peer3 = try PeerID(publicKey: keyPair3.publicKey)

            _ = bucket.insert(peer1)
            _ = bucket.insert(peer2)
            _ = bucket.insert(peer3)  // Goes to pending

            // Remove peer1, peer3 should be promoted
            _ = bucket.remove(peer1)

            #expect(bucket.count == 2)
            #expect(bucket.entry(for: peer3) != nil)
        }

        @Test("Entries sorted by distance")
        func entriesSortedByDistance() throws {
            var bucket = KBucket(maxSize: 10)

            var peers: [PeerID] = []
            for _ in 0..<5 {
                let keyPair = KeyPair.generateEd25519()
                let peer = try PeerID(publicKey: keyPair.publicKey)
                peers.append(peer)
                _ = bucket.insert(peer)
            }

            let target = KademliaKey(hashing: Data("target".utf8))
            let sorted = bucket.entriesSorted(by: target)

            // Verify sorted by distance
            for i in 0..<sorted.count - 1 {
                let dist1 = sorted[i].key.distance(to: target)
                let dist2 = sorted[i + 1].key.distance(to: target)
                #expect(dist1 < dist2 || dist1 == dist2)
            }
        }
    }

    // MARK: - RoutingTable Tests

    @Suite("RoutingTable Tests")
    struct RoutingTableTests {

        @Test("Add peer to routing table")
        func addPeer() throws {
            let localKeyPair = KeyPair.generateEd25519()
            let localPeer = try PeerID(publicKey: localKeyPair.publicKey)

            let table = RoutingTable(localPeerID: localPeer, kValue: 20)

            let remoteKeyPair = KeyPair.generateEd25519()
            let remotePeer = try PeerID(publicKey: remoteKeyPair.publicKey)

            let result = table.addPeer(remotePeer)
            #expect(result == .inserted)
            #expect(table.contains(remotePeer))
        }

        @Test("Cannot add self to routing table")
        func cannotAddSelf() throws {
            let localKeyPair = KeyPair.generateEd25519()
            let localPeer = try PeerID(publicKey: localKeyPair.publicKey)

            let table = RoutingTable(localPeerID: localPeer)

            let result = table.addPeer(localPeer)
            #expect(result == .selfEntry)
            #expect(!table.contains(localPeer))
        }

        @Test("Find closest peers")
        func closestPeers() throws {
            let localKeyPair = KeyPair.generateEd25519()
            let localPeer = try PeerID(publicKey: localKeyPair.publicKey)

            let table = RoutingTable(localPeerID: localPeer, kValue: 5)

            // Add some peers
            for _ in 0..<10 {
                let keyPair = KeyPair.generateEd25519()
                let peer = try PeerID(publicKey: keyPair.publicKey)
                _ = table.addPeer(peer)
            }

            let targetKey = KademliaKey(hashing: Data("target".utf8))
            let closest = table.closestPeers(to: targetKey, count: 5)

            #expect(closest.count <= 5)

            // Verify sorted by distance
            for i in 0..<closest.count - 1 {
                let dist1 = closest[i].key.distance(to: targetKey)
                let dist2 = closest[i + 1].key.distance(to: targetKey)
                #expect(dist1 < dist2 || dist1 == dist2)
            }
        }

        @Test("Remove peer from routing table")
        func removePeer() throws {
            let localKeyPair = KeyPair.generateEd25519()
            let localPeer = try PeerID(publicKey: localKeyPair.publicKey)

            let table = RoutingTable(localPeerID: localPeer)

            let remoteKeyPair = KeyPair.generateEd25519()
            let remotePeer = try PeerID(publicKey: remoteKeyPair.publicKey)

            _ = table.addPeer(remotePeer)
            let removed = table.removePeer(remotePeer)

            #expect(removed != nil)
            #expect(!table.contains(remotePeer))
        }

        @Test("Routing table statistics")
        func statistics() throws {
            let localKeyPair = KeyPair.generateEd25519()
            let localPeer = try PeerID(publicKey: localKeyPair.publicKey)

            let table = RoutingTable(localPeerID: localPeer, kValue: 20)

            for _ in 0..<5 {
                let keyPair = KeyPair.generateEd25519()
                let peer = try PeerID(publicKey: keyPair.publicKey)
                _ = table.addPeer(peer)
            }

            let stats = table.statistics
            #expect(stats.totalPeers == 5)
            #expect(stats.totalBuckets == 256)
            #expect(stats.kValue == 20)
        }
    }

    // MARK: - RecordStore Tests

    @Suite("RecordStore Tests")
    struct RecordStoreTests {

        @Test("Store and retrieve record")
        func storeAndRetrieve() {
            let store = RecordStore()
            let key = Data("mykey".utf8)
            let value = Data("myvalue".utf8)
            let record = KademliaRecord(key: key, value: value)

            let stored = store.put(record)
            #expect(stored)

            let retrieved = store.get(key)
            #expect(retrieved != nil)
            #expect(retrieved?.key == key)
            #expect(retrieved?.value == value)
        }

        @Test("Remove record")
        func removeRecord() {
            let store = RecordStore()
            let key = Data("mykey".utf8)
            let record = KademliaRecord(key: key, value: Data("value".utf8))

            _ = store.put(record)
            let removed = store.remove(key)

            #expect(removed != nil)
            #expect(store.get(key) == nil)
        }

        @Test("Record expires after TTL")
        func recordExpires() async throws {
            let store = RecordStore(defaultTTL: .milliseconds(50))
            let key = Data("mykey".utf8)
            let record = KademliaRecord(key: key, value: Data("value".utf8))

            _ = store.put(record)
            #expect(store.get(key) != nil)

            try await Task.sleep(for: .milliseconds(100))

            #expect(store.get(key) == nil)
        }

        @Test("Cleanup removes expired records")
        func cleanup() async throws {
            let store = RecordStore(defaultTTL: .milliseconds(50))

            for i in 0..<5 {
                let key = Data("key\(i)".utf8)
                let record = KademliaRecord(key: key, value: Data("value".utf8))
                _ = store.put(record)
            }

            #expect(store.count == 5)

            try await Task.sleep(for: .milliseconds(100))

            let removed = store.cleanup()
            #expect(removed == 5)
            #expect(store.count == 0)
        }
    }

    // MARK: - ProviderStore Tests

    @Suite("ProviderStore Tests")
    struct ProviderStoreTests {

        @Test("Add and get provider")
        func addAndGetProvider() throws {
            let store = ProviderStore()
            let contentKey = Data("content-cid".utf8)
            let keyPair = KeyPair.generateEd25519()
            let providerID = try PeerID(publicKey: keyPair.publicKey)

            let added = store.addProvider(for: contentKey, peerID: providerID)
            #expect(added)

            let providers = store.getProviders(for: contentKey)
            #expect(providers.count == 1)
            #expect(providers[0].peerID == providerID)
        }

        @Test("Multiple providers for same content")
        func multipleProviders() throws {
            let store = ProviderStore()
            let contentKey = Data("content-cid".utf8)

            for _ in 0..<3 {
                let keyPair = KeyPair.generateEd25519()
                let providerID = try PeerID(publicKey: keyPair.publicKey)
                _ = store.addProvider(for: contentKey, peerID: providerID)
            }

            let providers = store.getProviders(for: contentKey)
            #expect(providers.count == 3)
        }

        @Test("Remove provider")
        func removeProvider() throws {
            let store = ProviderStore()
            let contentKey = Data("content-cid".utf8)
            let keyPair = KeyPair.generateEd25519()
            let providerID = try PeerID(publicKey: keyPair.publicKey)

            _ = store.addProvider(for: contentKey, peerID: providerID)
            let removed = store.removeProvider(for: contentKey, peerID: providerID)

            #expect(removed != nil)
            #expect(store.getProviders(for: contentKey).isEmpty)
        }

        @Test("Provider expires after TTL")
        func providerExpires() async throws {
            let store = ProviderStore(defaultTTL: .milliseconds(50))
            let contentKey = Data("content-cid".utf8)
            let keyPair = KeyPair.generateEd25519()
            let providerID = try PeerID(publicKey: keyPair.publicKey)

            _ = store.addProvider(for: contentKey, peerID: providerID)
            #expect(store.hasProviders(for: contentKey))

            try await Task.sleep(for: .milliseconds(100))

            #expect(!store.hasProviders(for: contentKey))
        }
    }

    // MARK: - Protobuf Tests

    @Suite("Protobuf Tests")
    struct ProtobufTests {

        @Test("Encode and decode FIND_NODE request")
        func findNodeRequest() throws {
            let key = Data(repeating: 0x42, count: 32)
            let message = KademliaMessage.findNode(key: key)

            let encoded = KademliaProtobuf.encode(message)
            let decoded = try KademliaProtobuf.decode(encoded)

            #expect(decoded.type == .findNode)
            #expect(decoded.key == key)
        }

        @Test("Encode and decode FIND_NODE response")
        func findNodeResponse() throws {
            let keyPair = KeyPair.generateEd25519()
            let peerID = try PeerID(publicKey: keyPair.publicKey)
            let peer = KademliaPeer(id: peerID, addresses: [])

            let message = KademliaMessage.findNodeResponse(closerPeers: [peer])

            let encoded = KademliaProtobuf.encode(message)
            let decoded = try KademliaProtobuf.decode(encoded)

            #expect(decoded.type == .findNode)
            #expect(decoded.closerPeers.count == 1)
            #expect(decoded.closerPeers[0].id == peerID)
        }

        @Test("Encode and decode PUT_VALUE")
        func putValue() throws {
            let record = KademliaRecord(
                key: Data("mykey".utf8),
                value: Data("myvalue".utf8),
                timeReceived: "2024-01-01T00:00:00Z"
            )
            let message = KademliaMessage.putValue(record: record)

            let encoded = KademliaProtobuf.encode(message)
            let decoded = try KademliaProtobuf.decode(encoded)

            #expect(decoded.type == .putValue)
            #expect(decoded.record?.key == record.key)
            #expect(decoded.record?.value == record.value)
        }

        @Test("Encode and decode GET_PROVIDERS response")
        func getProvidersResponse() throws {
            let keyPair1 = KeyPair.generateEd25519()
            let keyPair2 = KeyPair.generateEd25519()

            let provider = KademliaPeer(id: try PeerID(publicKey: keyPair1.publicKey))
            let closer = KademliaPeer(id: try PeerID(publicKey: keyPair2.publicKey))

            let message = KademliaMessage.getProvidersResponse(
                providers: [provider],
                closerPeers: [closer]
            )

            let encoded = KademliaProtobuf.encode(message)
            let decoded = try KademliaProtobuf.decode(encoded)

            #expect(decoded.type == .getProviders)
            #expect(decoded.providerPeers.count == 1)
            #expect(decoded.closerPeers.count == 1)
        }
    }

    // MARK: - KademliaQuery Tests

    @Suite("KademliaQuery Tests")
    struct KademliaQueryTests {

        @Test("Query configuration defaults")
        func queryConfigDefaults() {
            let config = KademliaQueryConfig()

            #expect(config.alpha == KademliaProtocol.alphaValue)
            #expect(config.k == KademliaProtocol.kValue)
            #expect(config.maxIterations == 20)
        }

        @Test("Query creation with findNode type")
        func queryCreationFindNode() {
            let key = KademliaKey(hashing: Data("test".utf8))
            let query = KademliaQuery(type: .findNode(key))

            #expect(query.targetKey == key)
            if case .findNode(let k) = query.queryType {
                #expect(k == key)
            } else {
                Issue.record("Expected findNode query type")
            }
        }

        @Test("Query creation with getValue type")
        func queryCreationGetValue() {
            let rawKey = Data("mykey".utf8)
            let query = KademliaQuery(type: .getValue(rawKey))

            // getValue hashes the raw key
            let expectedKey = KademliaKey(hashing: rawKey)
            #expect(query.targetKey == expectedKey)
        }

        @Test("Query creation with getProviders type")
        func queryCreationGetProviders() {
            let rawKey = Data("content-cid".utf8)
            let query = KademliaQuery(type: .getProviders(rawKey))

            // getProviders hashes the raw key
            let expectedKey = KademliaKey(hashing: rawKey)
            #expect(query.targetKey == expectedKey)
        }

        @Test("Query fails with no initial peers")
        func queryFailsNoInitialPeers() async throws {
            let key = KademliaKey(hashing: Data("test".utf8))
            let query = KademliaQuery(type: .findNode(key))
            let delegate = MockKademliaQueryDelegate()

            do {
                _ = try await query.execute(initialPeers: [], delegate: delegate)
                Issue.record("Expected noPeersAvailable error")
            } catch let error as KademliaError {
                #expect(error == .noPeersAvailable)
            }
        }

        @Test("Query times out when delegate is slow")
        func queryTimesOut() async throws {
            let key = KademliaKey(hashing: Data("test".utf8))
            let config = KademliaQueryConfig(timeout: .milliseconds(100))
            let query = KademliaQuery(type: .findNode(key), config: config)

            // Create a delegate that delays responses
            let delegate = MockKademliaQueryDelegate()
            delegate.responseDelay = .seconds(10)  // Very slow

            let keyPair = KeyPair.generateEd25519()
            let peerID = try PeerID(publicKey: keyPair.publicKey)
            let initialPeer = KademliaPeer(id: peerID, addresses: [])

            do {
                _ = try await query.execute(initialPeers: [initialPeer], delegate: delegate)
                Issue.record("Expected timeout error")
            } catch let error as KademliaError {
                #expect(error == .timeout)
            }
        }

        @Test("Query succeeds before timeout")
        func querySucceedsBeforeTimeout() async throws {
            let key = KademliaKey(hashing: Data("test".utf8))
            let config = KademliaQueryConfig(timeout: .seconds(2))
            let query = KademliaQuery(type: .findNode(key), config: config)

            // Create a delegate with fast responses
            let delegate = MockKademliaQueryDelegate()
            delegate.responseDelay = .milliseconds(10)

            let keyPair = KeyPair.generateEd25519()
            let peerID = try PeerID(publicKey: keyPair.publicKey)
            let initialPeer = KademliaPeer(id: peerID, addresses: [])

            let result = try await query.execute(initialPeers: [initialPeer], delegate: delegate)

            if case .nodes(let peers) = result {
                // Should return the initial peer (since delegate returns empty list)
                #expect(peers.isEmpty || peers.count == 1)
            } else {
                Issue.record("Expected nodes result")
            }
        }
    }

    // MARK: - KademliaService Tests

    @Suite("KademliaService Tests")
    struct KademliaServiceTests {

        @Test("Create service")
        func createService() throws {
            let keyPair = KeyPair.generateEd25519()
            let localPeer = try PeerID(publicKey: keyPair.publicKey)

            let service = KademliaService(localPeerID: localPeer)

            #expect(service.localPeerID == localPeer)
            #expect(service.routingTable.isEmpty)
            #expect(service.protocolIDs.contains(KademliaProtocol.protocolID))
        }

        @Test("Add peer to service routing table")
        func addPeerToService() throws {
            let localKeyPair = KeyPair.generateEd25519()
            let localPeer = try PeerID(publicKey: localKeyPair.publicKey)

            let service = KademliaService(localPeerID: localPeer)

            let remoteKeyPair = KeyPair.generateEd25519()
            let remotePeer = try PeerID(publicKey: remoteKeyPair.publicKey)

            let result = service.addPeer(remotePeer)

            #expect(result == .inserted)
            #expect(service.routingTable.contains(remotePeer))
        }

        @Test("Local record lookup")
        func localRecordLookup() throws {
            let localKeyPair = KeyPair.generateEd25519()
            let localPeer = try PeerID(publicKey: localKeyPair.publicKey)

            let service = KademliaService(localPeerID: localPeer)

            let key = Data("testkey".utf8)
            let value = Data("testvalue".utf8)
            let record = KademliaRecord(key: key, value: value)

            _ = service.recordStore.put(record)

            let retrieved = service.recordStore.get(key)
            #expect(retrieved != nil)
            #expect(retrieved?.value == value)
        }

        @Test("Mode changes")
        func modeChanges() throws {
            let localKeyPair = KeyPair.generateEd25519()
            let localPeer = try PeerID(publicKey: localKeyPair.publicKey)

            let service = KademliaService(localPeerID: localPeer)

            #expect(service.mode == .automatic)

            service.setMode(.server)
            #expect(service.mode == .server)

            service.setMode(.client)
            #expect(service.mode == .client)
        }
    }

    // MARK: - Protocol Input Validation Tests

    @Suite("Protocol Input Validation Tests")
    struct ProtocolInputValidationTests {

        @Test("FIND_NODE message with invalid key length is rejected")
        func findNodeInvalidKeyLengthRejected() throws {
            // Create a FIND_NODE message with wrong key length (16 bytes instead of 32)
            let invalidKey = Data(repeating: 0x42, count: 16)
            let message = KademliaMessage.findNode(key: invalidKey)

            // When this message is handled, it should be rejected
            // We test the validation logic directly via KademliaKey
            do {
                _ = try KademliaKey(validating: invalidKey)
                Issue.record("Expected invalidLength error")
            } catch let error as KademliaKeyError {
                guard case .invalidLength(let actual, let expected) = error else {
                    Issue.record("Expected invalidLength error")
                    return
                }
                #expect(actual == 16)
                #expect(expected == 32)
            }

            // Verify message is created (protocol allows any bytes in key field)
            #expect(message.key == invalidKey)
        }

        @Test("FIND_NODE message with valid 32-byte key is accepted")
        func findNodeValidKeyAccepted() throws {
            let validKey = Data(repeating: 0x42, count: 32)

            // Should not throw
            let key = try KademliaKey(validating: validKey)
            #expect(key.bytes == validKey)

            // Message should be created successfully
            let message = KademliaMessage.findNode(key: validKey)
            #expect(message.key == validKey)
            #expect(message.type == .findNode)
        }

        @Test("GET_VALUE and GET_PROVIDERS accept arbitrary key lengths")
        func getValueAcceptsArbitraryKeyLength() throws {
            // These message types hash the key, so any length is valid
            let shortKey = Data("short".utf8)
            let longKey = Data(repeating: 0xFF, count: 1000)

            // Both should work because they use KademliaKey(hashing:)
            let hashShort = KademliaKey(hashing: shortKey)
            let hashLong = KademliaKey(hashing: longKey)

            #expect(hashShort.bytes.count == 32)
            #expect(hashLong.bytes.count == 32)

            // Messages should be created
            let getMessage = KademliaMessage.getValue(key: shortKey)
            #expect(getMessage.type == .getValue)

            let getProvidersMessage = KademliaMessage.getProviders(key: longKey)
            #expect(getProvidersMessage.type == .getProviders)
        }

        @Test("KademliaKeyError provides detailed error information")
        func kademliaKeyErrorDetails() {
            let error = KademliaKeyError.invalidLength(actual: 0, expected: 32)

            // Error should be Sendable
            let sendableError: (any Error & Sendable) = error

            // Error should be Equatable
            let sameError = KademliaKeyError.invalidLength(actual: 0, expected: 32)
            #expect(error == sameError)

            // Different values should not be equal
            let differentError = KademliaKeyError.invalidLength(actual: 64, expected: 32)
            #expect(error != differentError)

            // Verify we can access the associated values
            if case .invalidLength(let actual, let expected) = sendableError as? KademliaKeyError {
                #expect(actual == 0)
                #expect(expected == 32)
            }
        }

        @Test("Boundary condition: 31 bytes rejected")
        func boundaryCondition31Bytes() {
            let bytes31 = Data(repeating: 0x42, count: 31)

            do {
                _ = try KademliaKey(validating: bytes31)
                Issue.record("Expected invalidLength error for 31 bytes")
            } catch let error as KademliaKeyError {
                guard case .invalidLength(let actual, _) = error else {
                    Issue.record("Expected invalidLength error")
                    return
                }
                #expect(actual == 31)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        @Test("Boundary condition: 33 bytes rejected")
        func boundaryCondition33Bytes() {
            let bytes33 = Data(repeating: 0x42, count: 33)

            do {
                _ = try KademliaKey(validating: bytes33)
                Issue.record("Expected invalidLength error for 33 bytes")
            } catch let error as KademliaKeyError {
                guard case .invalidLength(let actual, _) = error else {
                    Issue.record("Expected invalidLength error")
                    return
                }
                #expect(actual == 33)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}

// MARK: - Mock Delegate

import Synchronization

/// Mock delegate for testing Kademlia queries.
final class MockKademliaQueryDelegate: KademliaQueryDelegate, Sendable {
    private let state = Mutex<DelegateState>(DelegateState())

    private struct DelegateState: Sendable {
        var responseDelay: Duration = .zero
        var findNodeResponse: [KademliaPeer] = []
        var getValueResponse: (record: KademliaRecord?, closerPeers: [KademliaPeer]) = (nil, [])
        var getProvidersResponse: (providers: [KademliaPeer], closerPeers: [KademliaPeer]) = ([], [])
    }

    var responseDelay: Duration {
        get { state.withLock { $0.responseDelay } }
        set { state.withLock { $0.responseDelay = newValue } }
    }

    var findNodeResponse: [KademliaPeer] {
        get { state.withLock { $0.findNodeResponse } }
        set { state.withLock { $0.findNodeResponse = newValue } }
    }

    func sendFindNode(to peer: PeerID, key: KademliaKey) async throws -> [KademliaPeer] {
        let delay = state.withLock { $0.responseDelay }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return state.withLock { $0.findNodeResponse }
    }

    func sendGetValue(to peer: PeerID, key: Data) async throws -> (record: KademliaRecord?, closerPeers: [KademliaPeer]) {
        let delay = state.withLock { $0.responseDelay }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return state.withLock { $0.getValueResponse }
    }

    func sendGetProviders(to peer: PeerID, key: Data) async throws -> (providers: [KademliaPeer], closerPeers: [KademliaPeer]) {
        let delay = state.withLock { $0.responseDelay }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return state.withLock { $0.getProvidersResponse }
    }
}
