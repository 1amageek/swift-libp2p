/// WebTransport transport implementation for libp2p.
///
/// WebTransport enables browser-based peers to connect to libp2p nodes
/// using HTTP/3 over QUIC. It provides the same security and multiplexing
/// benefits as QUIC, with the addition of browser compatibility.
///
/// ## Current Status
///
/// This is a stub implementation. HTTP/3 support in swift-quic is required
/// before WebTransport connections can be established. The transport correctly
/// validates addresses and returns `WebTransportError.http3NotAvailable`
/// for all connection attempts.
///
/// ## Multiaddr Format
///
/// WebTransport addresses extend QUIC addresses with the `webtransport`
/// protocol and certificate hashes:
///
/// ```
/// /ip4/<ip>/udp/<port>/quic-v1/webtransport/certhash/<hash>
/// /ip6/<ip>/udp/<port>/quic-v1/webtransport/certhash/<hash>
/// ```

import P2PCore

/// A libp2p transport using WebTransport over HTTP/3.
///
/// WebTransport provides:
/// - Browser compatibility (via the WebTransport Web API)
/// - Built-in TLS 1.3 security (inherited from QUIC)
/// - Native stream multiplexing (inherited from QUIC)
/// - Certificate hash-based verification (for self-signed certificates)
///
/// ## Usage
///
/// ```swift
/// let transport = WebTransportTransport()
///
/// // Check if an address is a WebTransport address
/// let canDial = transport.canDial(address)
///
/// // Dial will throw until HTTP/3 is available
/// let connection = try await transport.dial(to: address)
/// ```
public final class WebTransportTransport: Sendable {

    /// The WebTransport configuration.
    public let configuration: WebTransportConfiguration

    /// Creates a new WebTransport transport.
    ///
    /// - Parameter configuration: Transport configuration (defaults to standard settings)
    public init(configuration: WebTransportConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Checks if an address is a valid WebTransport address.
    ///
    /// A valid WebTransport address must contain, in order:
    /// 1. An IP protocol (ip4 or ip6)
    /// 2. A UDP port
    /// 3. quic-v1
    /// 4. webtransport
    ///
    /// The address format is:
    /// `/ip4/<ip>/udp/<port>/quic-v1/webtransport[/certhash/<hash>]`
    ///
    /// - Parameter address: The multiaddr to check
    /// - Returns: `true` if the address is a valid WebTransport address
    public func canDial(_ address: Multiaddr) -> Bool {
        let protos = address.protocols

        // Find indices of required protocols and validate ordering
        var ipIndex: Int?
        var udpIndex: Int?
        var quicIndex: Int?
        var wtIndex: Int?

        for (index, proto) in protos.enumerated() {
            switch proto {
            case .ip4, .ip6:
                if ipIndex == nil { ipIndex = index }
            case .udp:
                if udpIndex == nil { udpIndex = index }
            case .quicV1:
                if quicIndex == nil { quicIndex = index }
            case .webtransport:
                if wtIndex == nil { wtIndex = index }
            default:
                break
            }
        }

        // All four protocols must be present
        guard let ip = ipIndex,
              let udp = udpIndex,
              let quic = quicIndex,
              let wt = wtIndex else {
            return false
        }

        // Validate ordering: IP < UDP < QUIC < WebTransport
        return ip < udp && udp < quic && quic < wt
    }

    /// Dials a WebTransport address.
    ///
    /// - Important: This method currently always throws `WebTransportError.http3NotAvailable`
    ///   because HTTP/3 support is not yet available in the underlying QUIC implementation.
    ///
    /// - Parameter address: The multiaddr to dial
    /// - Returns: A WebTransport connection
    /// - Throws: `WebTransportError.http3NotAvailable`
    public func dial(to address: Multiaddr) async throws -> WebTransportConnection {
        throw WebTransportError.http3NotAvailable
    }

    /// Extracts certificate hashes from a WebTransport multiaddr.
    ///
    /// - Parameter address: The multiaddr containing certhash components
    /// - Returns: An array of certificate hash data
    public func extractCertHashes(from address: Multiaddr) -> [[UInt8]] {
        var hashes: [[UInt8]] = []
        for proto in address.protocols {
            if case .certhash(let data) = proto {
                hashes.append(Array(data))
            }
        }
        return hashes
    }

    // MARK: - Private

    /// Checks whether the address contains a certhash component.
    private func hasCertHash(_ address: Multiaddr) -> Bool {
        address.protocols.contains { proto in
            if case .certhash = proto {
                return true
            }
            return false
        }
    }
}
