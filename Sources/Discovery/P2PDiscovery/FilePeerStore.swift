/// FilePeerStore - File-backed PeerStore with periodic persistence
///
/// Uses MemoryPeerStore as a hot cache and periodically flushes
/// peer data to a JSON file on disk. On initialization, loads
/// existing data from the file if present.

import Foundation
import P2PCore
import Synchronization

// MARK: - Configuration

/// Configuration for FilePeerStore.
public struct FilePeerStoreConfiguration: Sendable {

    /// Directory where peer data files are stored.
    public let directory: URL

    /// Interval between automatic flush operations.
    public let flushInterval: Duration

    /// Configuration for the underlying memory store.
    public let memoryConfig: MemoryPeerStoreConfiguration

    public init(
        directory: URL,
        flushInterval: Duration = .seconds(30),
        memoryConfig: MemoryPeerStoreConfiguration = .default
    ) {
        self.directory = directory
        self.flushInterval = flushInterval
        self.memoryConfig = memoryConfig
    }
}

// MARK: - Persistence Models

/// Codable representation of a stored peer and its addresses.
private struct StoredPeerData: Codable, Sendable {
    let peerID: String
    let addresses: [StoredAddress]
}

/// Codable representation of a stored address with failure metadata.
private struct StoredAddress: Codable, Sendable {
    let address: String
    let failureCount: Int
}

// MARK: - FilePeerStore

/// File-backed PeerStore.
///
/// Wraps MemoryPeerStore with periodic disk persistence.
/// Data is loaded from disk on initialization and flushed periodically.
///
/// ## Lifecycle
///
/// ```swift
/// let store = FilePeerStore(configuration: config)
/// try await store.start()  // loads data, starts periodic flush
/// // ... use store ...
/// await store.stop()       // final flush, cleanup
/// ```
public actor FilePeerStore: PeerStore {

    private let config: FilePeerStoreConfiguration
    private let memoryStore: MemoryPeerStore
    private var flushTask: Task<Void, Never>?
    private var isDirty: Bool = false

    /// The file path for stored data.
    private var dataFilePath: URL {
        config.directory.appendingPathComponent("peerstore.json")
    }

    public init(configuration: FilePeerStoreConfiguration) {
        self.config = configuration
        self.memoryStore = MemoryPeerStore(configuration: configuration.memoryConfig)
    }

    /// Loads existing data and starts periodic flush.
    public func start() async throws {
        try FileManager.default.createDirectory(
            at: config.directory,
            withIntermediateDirectories: true
        )

        await loadFromDisk()

        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let s = self else { return }
                let interval = s.config.flushInterval
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let s = self else { return }
                await s.flushIfDirty()
            }
        }
    }

    /// Stops periodic flush and performs a final flush.
    public func stop() async {
        flushTask?.cancel()
        flushTask = nil
        do {
            try await flush()
        } catch {
            // Log error but don't throw from stop
        }
        memoryStore.shutdown()
    }

    /// Forces an immediate flush to disk.
    public func flush() async throws {
        try await saveToDisk()
        isDirty = false
    }

    // MARK: - PeerStore Protocol

    public nonisolated var events: AsyncStream<PeerStoreEvent> {
        memoryStore.events
    }

    public func addresses(for peer: PeerID) async -> [Multiaddr] {
        await memoryStore.addresses(for: peer)
    }

    public func addAddresses(_ addresses: [Multiaddr], for peer: PeerID, ttl: Duration?) async {
        await memoryStore.addAddresses(addresses, for: peer, ttl: ttl)
        isDirty = true
    }

    public func removeAddress(_ address: Multiaddr, for peer: PeerID) async {
        await memoryStore.removeAddress(address, for: peer)
        isDirty = true
    }

    public func removePeer(_ peer: PeerID) async {
        await memoryStore.removePeer(peer)
        isDirty = true
    }

    public func allPeers() async -> [PeerID] {
        await memoryStore.allPeers()
    }

    public func peerCount() async -> Int {
        await memoryStore.peerCount()
    }

    public func addressRecord(_ address: Multiaddr, for peer: PeerID) async -> AddressRecord? {
        await memoryStore.addressRecord(address, for: peer)
    }

    public func addressRecords(for peer: PeerID) async -> [Multiaddr: AddressRecord] {
        await memoryStore.addressRecords(for: peer)
    }

    public func recordSuccess(address: Multiaddr, for peer: PeerID) async {
        await memoryStore.recordSuccess(address: address, for: peer)
        isDirty = true
    }

    public func recordFailure(address: Multiaddr, for peer: PeerID) async {
        await memoryStore.recordFailure(address: address, for: peer)
        isDirty = true
    }

    // MARK: - Private

    private func flushIfDirty() async {
        guard isDirty else { return }
        do {
            try await flush()
        } catch {
            // Flush failed - will retry on next interval
        }
    }

    private func loadFromDisk() async {
        let path = dataFilePath
        guard FileManager.default.fileExists(atPath: path.path) else { return }

        do {
            let data = try Data(contentsOf: path)
            let stored = try JSONDecoder().decode([StoredPeerData].self, from: data)

            for peerData in stored {
                do {
                    let peerID = try PeerID(string: peerData.peerID)
                    var restoredAddresses: [(address: Multiaddr, failureCount: Int)] = []
                    for storedAddr in peerData.addresses {
                        do {
                            let addr = try Multiaddr(storedAddr.address)
                            restoredAddresses.append((address: addr, failureCount: storedAddr.failureCount))
                        } catch {
                            // Skip invalid address entries
                            continue
                        }
                    }
                    if !restoredAddresses.isEmpty {
                        memoryStore.restoreAddresses(restoredAddresses, for: peerID, ttl: nil)
                    }
                } catch {
                    // Skip corrupted peer entries
                    continue
                }
            }
        } catch {
            // File is corrupted or unreadable - start fresh
        }
    }

    private func saveToDisk() async throws {
        let peers = await memoryStore.allPeers()
        var stored: [StoredPeerData] = []

        for peer in peers {
            let addresses = await memoryStore.addresses(for: peer)
            let records = await memoryStore.addressRecords(for: peer)

            let storedAddresses: [StoredAddress] = addresses.map { addr in
                let record = records[addr]
                return StoredAddress(
                    address: addr.description,
                    failureCount: record?.failureCount ?? 0
                )
            }

            stored.append(StoredPeerData(
                peerID: peer.description,
                addresses: storedAddresses
            ))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        try data.write(to: dataFilePath, options: .atomic)
    }
}
