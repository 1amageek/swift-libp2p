/// P2PDiscoveryMDNS - Codec for encoding/decoding PeerID to/from an MDNSService
import Foundation
import P2PCore
import P2PCoreTransport
import P2PDiscovery
import MDNS

/// TXT record keys for libp2p peer information.
public enum PeerTXTKey {
    /// Base64-encoded public key.
    public static let publicKey = "pk"
    /// Agent version string.
    public static let agentVersion = "agent"
    /// Comma-separated protocol IDs.
    public static let protocols = "protos"
    /// One or more `dnsaddr` multiaddrs (see `dnsaddrSeparator`).
    public static let dnsaddr = "dnsaddr"
}

/// Codec for converting between PeerID/Multiaddr and an `MDNSService`.
public enum PeerIDServiceCodec {

    /// Separator packing MULTIPLE `dnsaddr` multiaddrs into the single
    /// `MDNSService.txt["dnsaddr"]` value.
    ///
    /// The Tier-1 `MDNS` facade models TXT attributes as `[String: [UInt8]]`
    /// (ONE value per key), whereas the libp2p mDNS spec advertises MULTIPLE
    /// `dnsaddr` TXT entries. We pack them into one value separated by a newline.
    /// A multiaddr text representation is a `/`-delimited token sequence and never
    /// contains a newline, so `\n` is an unambiguous, lossless separator.
    private static let dnsaddrSeparator: Character = "\n"

    // MARK: - TXT helpers

    /// Reads a single UTF-8 TXT value for `key`, or nil if absent/non-UTF-8.
    private static func txtString(_ txt: [String: [UInt8]], _ key: String) -> String? {
        guard let bytes = txt[key] else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads the packed `dnsaddr` TXT value and splits it into the individual
    /// multiaddr strings (empty if the key is absent).
    private static func dnsaddrValues(_ txt: [String: [UInt8]]) -> [String] {
        guard let packed = txtString(txt, PeerTXTKey.dnsaddr) else { return [] }
        return packed
            .split(separator: dnsaddrSeparator, omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: - IP rendering

    /// Renders an `IPAddress` to its canonical text form for multiaddr building.
    ///
    /// `P2PCoreTransport.IPAddress` is Foundation-free and is NOT
    /// `CustomStringConvertible`, so we render from `rawBytes` directly:
    /// dotted-quad for IPv4, fully-expanded 8-group hextet form for IPv6.
    private static func renderIP(_ address: P2PCoreTransport.IPAddress) -> String {
        let bytes = address.rawBytes
        if address.isIPv4, bytes.count == 4 {
            return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
        }
        guard bytes.count == 16 else {
            // Defensive: an address with neither 4 nor 16 bytes is malformed.
            // Render the IPv4 octets if possible, else an empty (invalid) string
            // so the caller's `Multiaddr(...)` parse rejects it rather than
            // fabricating an address.
            return bytes.count == 4
                ? "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
                : ""
        }
        var groups: [String] = []
        var i = 0
        while i < 16 {
            let group = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            groups.append(String(group, radix: 16))
            i += 2
        }
        return groups.joined(separator: ":")
    }

    /// Whether an IPv6 `IPAddress` is link-local (fe80::/10).
    private static func isIPv6LinkLocal(_ address: P2PCoreTransport.IPAddress) -> Bool {
        let bytes = address.rawBytes
        guard bytes.count == 16 else { return false }
        let leading16 = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return (leading16 & 0xFFC0) == 0xFE80
    }

    // MARK: - Encode

    /// Encodes a PeerID and addresses into an `MDNSService`.
    ///
    /// - Parameters:
    ///   - peerID: The local peer ID.
    ///   - addresses: The addresses to advertise.
    ///   - port: The port number.
    ///   - configuration: The mDNS configuration.
    ///   - serviceName: Optional service instance name override.
    /// - Returns: An `MDNSService` ready to be advertised.
    public static func encode(
        peerID: PeerID,
        addresses: [Multiaddr],
        port: UInt16,
        configuration: MDNSConfiguration,
        serviceName: String? = nil
    ) -> MDNSService {
        var txt: [String: [UInt8]] = [:]

        // Encode public key if available (not all key types support extraction)
        do {
            if let publicKey = try peerID.extractPublicKey() {
                txt[PeerTXTKey.publicKey] = Array(
                    publicKey.protobufEncoded.base64EncodedString().utf8
                )
            }
        } catch {
            // Public key not extractable for this key type - omit from TXT record
        }

        // Agent version
        txt[PeerTXTKey.agentVersion] = Array(configuration.agentVersion.utf8)

        // Encode multiaddresses as dnsaddr TXT attributes (libp2p mDNS spec),
        // packed into a single newline-separated value (see `dnsaddrSeparator`).
        var dnsaddrStrings: [String] = []
        for var addr in addresses {
            do {
                // Ensure p2p component is present
                if !addr.hasPeerID {
                    addr = try addr.appending(.p2p(peerID))
                }
                dnsaddrStrings.append(addr.description)
            } catch {
                // Skip invalid multiaddr (per-element validation, not systemic)
                continue
            }
        }
        if !dnsaddrStrings.isEmpty {
            let packed = dnsaddrStrings.joined(separator: String(dnsaddrSeparator))
            txt[PeerTXTKey.dnsaddr] = Array(packed.utf8)
        }

        // Extract protocol information from addresses (backward compatibility)
        let protocols = extractProtocols(from: addresses)
        if !protocols.isEmpty {
            txt[PeerTXTKey.protocols] = Array(protocols.joined(separator: ",").utf8)
        }

        return MDNSService(
            name: serviceName ?? peerID.description,
            type: configuration.serviceType,
            domain: configuration.domain,
            port: port,
            txt: txt,
            ttl: configuration.ttl
        )
    }

    // MARK: - Decode

    /// Decodes an `MDNSService` into a ScoredCandidate.
    ///
    /// - Parameters:
    ///   - service: The `MDNSService` to decode.
    ///   - observer: The local peer ID observing this service.
    /// - Returns: A ScoredCandidate.
    /// - Throws: `MDNSDiscoveryError.invalidPeerID` if the service name is not a valid peer ID.
    public static func decode(
        service: MDNSService,
        observer: PeerID
    ) throws -> ScoredCandidate {
        let peerID = try inferPeerID(from: service)

        var addresses: [Multiaddr] = []

        // Priority 1: Read dnsaddr TXT attributes (libp2p mDNS spec)
        for addrString in dnsaddrValues(service.txt) {
            do {
                let normalized = normalizeScopedIPv6InMultiaddr(addrString)
                var addr = try Multiaddr(normalized)

                // Validate peer ID component
                if let addrPeerID = addr.peerID {
                    guard addrPeerID == peerID else {
                        // Peer ID mismatch - skip this address
                        continue
                    }
                } else {
                    // Add p2p component if missing
                    addr = try addr.appending(.p2p(peerID))
                }

                addresses.append(addr)
            } catch {
                // Invalid multiaddr - skip and continue (per-element validation)
                continue
            }
        }

        // Fallback: Build addresses from A/AAAA records + port
        // (backward compatibility and for peers not using dnsaddr)
        if addresses.isEmpty, let port = service.port {
            // Add IPv4 addresses (TCP — mDNS-SD advertises TCP service ports)
            for ipv4 in service.ipv4Addresses {
                var addr = try Multiaddr("/ip4/\(renderIP(ipv4))/tcp/\(port)")
                addr = try addr.appending(.p2p(peerID))
                addresses.append(addr)
            }

            // Add IPv6 addresses
            for ipv6 in service.ipv6Addresses {
                // Link-local IPv6 addresses require a zone/scope ID for reachability.
                // Service A/AAAA records do not carry scope information, so skip them.
                guard !isIPv6LinkLocal(ipv6) else { continue }
                var addr = try Multiaddr("/ip6/\(renderIP(ipv6))/tcp/\(port)")
                addr = try addr.appending(.p2p(peerID))
                addresses.append(addr)
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

    /// Creates an Observation from a discovered `MDNSService`.
    ///
    /// - Parameters:
    ///   - service: The discovered service.
    ///   - kind: The observation kind.
    ///   - observer: The local peer ID.
    ///   - sequenceNumber: The sequence number for ordering.
    /// - Returns: An Observation.
    /// - Throws: `MDNSDiscoveryError.invalidPeerID` if the service name is not a valid peer ID.
    public static func toObservation(
        service: MDNSService,
        kind: PeerObservation.Kind,
        observer: PeerID,
        sequenceNumber: UInt64
    ) throws -> PeerObservation {
        let peerID = try inferPeerID(from: service)

        var hints: [Multiaddr] = []

        // Priority 1: Read dnsaddr TXT attributes (consistent with decode())
        for addrString in dnsaddrValues(service.txt) {
            do {
                let normalized = normalizeScopedIPv6InMultiaddr(addrString)
                var addr = try Multiaddr(normalized)

                // Validate peer ID component
                if let addrPeerID = addr.peerID {
                    guard addrPeerID == peerID else {
                        continue
                    }
                } else {
                    // Add p2p component if missing
                    addr = try addr.appending(.p2p(peerID))
                }

                hints.append(addr)
            } catch {
                // Invalid multiaddr - skip and continue (per-element validation)
                continue
            }
        }

        // Fallback: Build address hints from A/AAAA records + port
        if hints.isEmpty, let port = service.port {
            for ipv4 in service.ipv4Addresses {
                var addr = try Multiaddr("/ip4/\(renderIP(ipv4))/tcp/\(port)")
                addr = try addr.appending(.p2p(peerID))
                hints.append(addr)
            }
            for ipv6 in service.ipv6Addresses {
                // Link-local IPv6 addresses require a zone/scope ID for reachability.
                // Service A/AAAA records do not carry scope information, so skip them.
                guard !isIPv6LinkLocal(ipv6) else { continue }
                var addr = try Multiaddr("/ip6/\(renderIP(ipv6))/tcp/\(port)")
                addr = try addr.appending(.p2p(peerID))
                hints.append(addr)
            }
        }

        return PeerObservation(
            subject: peerID,
            observer: observer,
            kind: kind,
            hints: hints,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            sequenceNumber: sequenceNumber
        )
    }

    /// Infers the peer ID represented by an `MDNSService`.
    ///
    /// Resolution order:
    /// 1. PeerID embedded in `dnsaddr` TXT values (`/p2p/<peerID>`)
    /// 2. PeerID derived from `pk` TXT value (protobuf-encoded public key)
    /// 3. Legacy fallback: parse service instance name as PeerID
    public static func inferPeerID(from service: MDNSService) throws -> PeerID {
        if let dnsaddrPeerID = peerIDFromDNSAddrTXT(service: service) {
            return dnsaddrPeerID
        }

        if let publicKeyPeerID = peerIDFromPublicKeyTXT(service: service) {
            return publicKeyPeerID
        }

        do {
            return try PeerID(string: service.name)
        } catch {
            throw MDNSDiscoveryError.invalidPeerID(service.name)
        }
    }

    // MARK: - Private Helpers

    private static func peerIDFromDNSAddrTXT(service: MDNSService) -> PeerID? {
        var peerIDs = Set<PeerID>()

        for value in dnsaddrValues(service.txt) {
            do {
                let normalized = normalizeScopedIPv6InMultiaddr(value)
                let addr = try Multiaddr(normalized)
                if let peerID = addr.peerID {
                    peerIDs.insert(peerID)
                }
            } catch {
                continue
            }
        }

        if peerIDs.count == 1 {
            return peerIDs.first
        }

        return nil
    }

    private static func peerIDFromPublicKeyTXT(service: MDNSService) -> PeerID? {
        guard let encoded = txtString(service.txt, PeerTXTKey.publicKey), !encoded.isEmpty else {
            return nil
        }

        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }

        // Preferred format: protobuf-encoded libp2p public key
        do {
            let publicKey = try PublicKey(protobufEncoded: data)
            return publicKey.peerID
        } catch {
            // Backward compatibility: legacy raw Ed25519 bytes
        }

        do {
            let publicKey = try PublicKey(keyType: .ed25519, rawBytes: data)
            return publicKey.peerID
        } catch {
            return nil
        }
    }

    private static func extractProtocols(from addresses: [Multiaddr]) -> [String] {
        var protocols = Set<String>()
        for addr in addresses {
            for component in addr.protocols {
                protocols.insert(component.name)
            }
        }
        return Array(protocols).sorted()
    }

    private static func calculateScore(service: MDNSService, addressCount: Int) -> Double {
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

    /// Converts `/ip6/<addr>%<zone>/...` segments to `/ip6zone/<zone>/ip6/<addr>/...`.
    ///
    /// This preserves zone information in canonical multiaddr form and keeps
    /// compatibility with peers that still encode scoped IPv6 as `%zone` in `ip6`.
    private static func normalizeScopedIPv6InMultiaddr(_ value: String) -> String {
        let components = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return value }

        var result: [String] = []
        var index = 0

        while index < components.count {
            let proto = components[index]

            if proto == "ip6", index + 1 < components.count {
                let ipValue = components[index + 1]
                if let percent = ipValue.firstIndex(of: "%") {
                    let base = String(ipValue[..<percent])
                    let zoneStart = ipValue.index(after: percent)
                    let zone = String(ipValue[zoneStart...])

                    if !base.isEmpty, MultiaddrProtocol.isValidZoneID(zone) {
                        result.append("ip6zone")
                        result.append(zone)
                        result.append("ip6")
                        result.append(base)
                        index += 2
                        continue
                    }
                }
            }

            result.append(proto)
            index += 1
        }

        return "/" + result.joined(separator: "/")
    }
}
