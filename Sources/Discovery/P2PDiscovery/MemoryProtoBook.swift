/// P2PDiscovery - MemoryProtoBook
///
/// In-memory implementation of ProtoBook using Mutex for thread-safe,
/// high-frequency internal access.

import P2PCore
import Synchronization

// MARK: - MemoryProtoBook

/// In-memory implementation of ProtoBook.
///
/// Uses `Mutex` for thread-safe access (high-frequency internal pattern).
public final class MemoryProtoBook: ProtoBook, Sendable {

    private let state: Mutex<State>

    private struct State: Sendable {
        var protocols: [PeerID: Set<String>] = [:]
        /// Reverse index: protocol ID → peers supporting it
        var protocolPeers: [String: Set<PeerID>] = [:]
    }

    /// Creates a new in-memory ProtoBook.
    public init() {
        self.state = Mutex(State())
    }

    public func protocols(for peer: PeerID) async -> [String] {
        state.withLock { Array($0.protocols[peer] ?? []) }
    }

    public func setProtocols(_ protocols: [String], for peer: PeerID) async {
        state.withLock { s in
            // Remove peer from old reverse index entries
            if let oldProtocols = s.protocols[peer] {
                for proto in oldProtocols {
                    s.protocolPeers[proto]?.remove(peer)
                    if s.protocolPeers[proto]?.isEmpty == true {
                        s.protocolPeers.removeValue(forKey: proto)
                    }
                }
            }
            // Set new protocols
            let newSet = Set(protocols)
            s.protocols[peer] = newSet
            // Add peer to new reverse index entries
            for proto in newSet {
                s.protocolPeers[proto, default: []].insert(peer)
            }
        }
    }

    public func addProtocols(_ protocols: [String], for peer: PeerID) async {
        state.withLock { s in
            var set = s.protocols[peer] ?? []
            set.formUnion(protocols)
            s.protocols[peer] = set
            // Update reverse index for added protocols
            for proto in protocols {
                s.protocolPeers[proto, default: []].insert(peer)
            }
        }
    }

    public func removeProtocols(_ protocols: [String], from peer: PeerID) async {
        state.withLock { s in
            s.protocols[peer]?.subtract(protocols)
            // Update reverse index for removed protocols
            for proto in protocols {
                s.protocolPeers[proto]?.remove(peer)
                if s.protocolPeers[proto]?.isEmpty == true {
                    s.protocolPeers.removeValue(forKey: proto)
                }
            }
            if s.protocols[peer]?.isEmpty == true {
                s.protocols.removeValue(forKey: peer)
            }
        }
    }

    public func supportsProtocols(_ protocols: [String], for peer: PeerID) async -> [String] {
        state.withLock { s in
            guard let supported = s.protocols[peer] else { return [] }
            return protocols.filter { supported.contains($0) }
        }
    }

    public func firstSupportedProtocol(_ protocols: [String], for peer: PeerID) async -> String? {
        state.withLock { s in
            guard let supported = s.protocols[peer] else { return nil }
            return protocols.first { supported.contains($0) }
        }
    }

    public func removePeer(_ peer: PeerID) async {
        state.withLock { s in
            if let oldProtocols = s.protocols.removeValue(forKey: peer) {
                for proto in oldProtocols {
                    s.protocolPeers[proto]?.remove(peer)
                    if s.protocolPeers[proto]?.isEmpty == true {
                        s.protocolPeers.removeValue(forKey: proto)
                    }
                }
            }
        }
    }

    public func peers(supporting protocolID: String) async -> [PeerID] {
        state.withLock { s in
            Array(s.protocolPeers[protocolID] ?? [])
        }
    }
}
