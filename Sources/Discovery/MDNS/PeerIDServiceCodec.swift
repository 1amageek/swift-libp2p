/// P2PDiscoveryMDNS - Codec for encoding/decoding PeerID to/from mDNS Service
import Foundation
import P2PCore
import P2PDiscovery
import mDNS

/// TXT record keys for libp2p peer information.
public enum PeerTXTKey {
    /// Base64-encoded public key.
    public static let publicKey = "pk"
    /// Agent version string.
    public static let agentVersion = "agent"
    /// Comma-separated protocol IDs.
    public static let protocols = "protos"
}

/// Codec for converting between PeerID/Multiaddr and mDNS Service.
public enum PeerIDServiceCodec {

    /// Encodes a PeerID and addresses into an mDNS Service.
    ///
    /// - Parameters:
    ///   - peerID: The local peer ID.
    ///   - addresses: The addresses to advertise.
    ///   - port: The port number.
    ///   - configuration: The mDNS configuration.
    /// - Returns: An mDNS Service ready to be advertised.
    public static func encode(
        peerID: PeerID,
        addresses: [Multiaddr],
        port: UInt16,
        configuration: MDNSConfiguration
    ) -> Service {
        var txtRecord = TXTRecord()

        // Encode public key if available
        if let publicKey = try? peerID.extractPublicKey() {
            txtRecord[PeerTXTKey.publicKey] = publicKey.rawBytes.base64EncodedString()
        }

        // Agent version
        txtRecord[PeerTXTKey.agentVersion] = configuration.agentVersion

        // Extract protocol information from addresses
        let protocols = extractProtocols(from: addresses)
        if !protocols.isEmpty {
            txtRecord[PeerTXTKey.protocols] = protocols.joined(separator: ",")
        }

        return Service(
            name: peerID.description,
            type: configuration.serviceType,
            domain: configuration.domain,
            port: port,
            txtRecord: txtRecord,
            ttl: configuration.ttl
        )
    }

    /// Decodes an mDNS Service into a ScoredCandidate.
    ///
    /// - Parameters:
    ///   - service: The mDNS Service to decode.
    ///   - observer: The local peer ID observing this service.
    /// - Returns: A ScoredCandidate, or nil if decoding fails.
    public static func decode(
        service: Service,
        observer: PeerID
    ) -> ScoredCandidate? {
        // Parse PeerID from service name (base58 encoded)
        guard let peerID = try? PeerID(string: service.name) else {
            return nil
        }

        // Build addresses from resolved service info
        var addresses: [Multiaddr] = []

        if let port = service.port {
            // Add IPv4 addresses
            for ipv4 in service.ipv4Addresses {
                if let addr = try? Multiaddr("/ip4/\(ipv4)/udp/\(port)") {
                    addresses.append(addr)
                }
                if let addr = try? Multiaddr("/ip4/\(ipv4)/tcp/\(port)") {
                    addresses.append(addr)
                }
            }

            // Add IPv6 addresses
            for ipv6 in service.ipv6Addresses {
                if let addr = try? Multiaddr("/ip6/\(ipv6)/udp/\(port)") {
                    addresses.append(addr)
                }
                if let addr = try? Multiaddr("/ip6/\(ipv6)/tcp/\(port)") {
                    addresses.append(addr)
                }
            }
        }

        // Score based on resolution completeness
        let score = calculateScore(service: service, addressCount: addresses.count)

        return ScoredCandidate(
            peerID: peerID,
            addresses: addresses,
            score: score
        )
    }

    /// Creates an Observation from a service browser event.
    ///
    /// - Parameters:
    ///   - service: The discovered service.
    ///   - kind: The observation kind.
    ///   - observer: The local peer ID.
    ///   - sequenceNumber: The sequence number for ordering.
    /// - Returns: An Observation, or nil if the service cannot be decoded.
    public static func toObservation(
        service: Service,
        kind: Observation.Kind,
        observer: PeerID,
        sequenceNumber: UInt64
    ) -> Observation? {
        guard let peerID = try? PeerID(string: service.name) else {
            return nil
        }

        // Build address hints
        var hints: [Multiaddr] = []
        if let port = service.port {
            for ipv4 in service.ipv4Addresses {
                if let addr = try? Multiaddr("/ip4/\(ipv4)/udp/\(port)") {
                    hints.append(addr)
                }
            }
            for ipv6 in service.ipv6Addresses {
                if let addr = try? Multiaddr("/ip6/\(ipv6)/udp/\(port)") {
                    hints.append(addr)
                }
            }
        }

        return Observation(
            subject: peerID,
            observer: observer,
            kind: kind,
            hints: hints,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            sequenceNumber: sequenceNumber
        )
    }

    // MARK: - Private Helpers

    private static func extractProtocols(from addresses: [Multiaddr]) -> [String] {
        var protocols = Set<String>()
        for addr in addresses {
            for component in addr.protocols {
                protocols.insert(component.name)
            }
        }
        return Array(protocols).sorted()
    }

    private static func calculateScore(service: Service, addressCount: Int) -> Double {
        var score = 0.5  // Base score for discovery

        // Bonus for being fully resolved
        if service.isResolved {
            score += 0.2
        }

        // Bonus for having addresses
        if addressCount > 0 {
            score += 0.2
        }

        // Bonus for having both IPv4 and IPv6
        if !service.ipv4Addresses.isEmpty && !service.ipv6Addresses.isEmpty {
            score += 0.1
        }

        return min(score, 1.0)
    }
}
