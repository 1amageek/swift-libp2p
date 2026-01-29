/// WebRTC Direct Transport for libp2p
///
/// Implements SecuredTransport using WebRTC Direct (DTLS 1.2 + SCTP).
/// Like QUIC, WebRTC provides built-in security and multiplexing,
/// so it bypasses the standard libp2p upgrade pipeline.
///
/// Multiaddr format: `/ip4/<ip>/udp/<port>/webrtc-direct/certhash/<hash>`
///
/// Note: This transport is not self-contained for UDP I/O.
/// The sendHandler must be provided by the integration layer
/// (e.g., P2P.addTransport()) that owns the UDP socket.

import Foundation
import P2PCore
import P2PTransport
import P2PMux
import P2PCertificate
import WebRTC
import DTLSCore

/// A libp2p transport using WebRTC Direct.
///
/// WebRTC Direct provides:
/// - DTLS 1.2 encryption (security)
/// - SCTP-based data channels (multiplexing)
/// - UDP-based, NAT traversal friendly
///
/// Unlike TCP, WebRTC Direct connections bypass the standard libp2p upgrade
/// pipeline because security and multiplexing are native to the protocol.
public final class WebRTCTransport: SecuredTransport, Sendable {

    /// Supported protocol chains.
    ///
    /// WebRTC Direct uses UDP as the underlying transport:
    /// - `/ip4/<ip>/udp/<port>/webrtc-direct`
    /// - `/ip6/<ip>/udp/<port>/webrtc-direct`
    public var protocols: [[String]] {
        [["ip4", "udp", "webrtc-direct"], ["ip6", "udp", "webrtc-direct"]]
    }

    public init() {}

    // MARK: - Transport Protocol

    /// Not supported for WebRTC — use `dialSecured` instead.
    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        throw TransportError.unsupportedOperation("WebRTC requires SecuredTransport.dialSecured()")
    }

    /// Not supported for WebRTC — use `listenSecured` instead.
    public func listen(_ address: Multiaddr) async throws -> any Listener {
        throw TransportError.unsupportedOperation("WebRTC requires SecuredTransport.listenSecured()")
    }

    /// Whether this transport can dial the given address.
    public func canDial(_ address: Multiaddr) -> Bool {
        extractWebRTCComponents(from: address) != nil
    }

    /// Whether this transport can listen on the given address.
    public func canListen(_ address: Multiaddr) -> Bool {
        guard address.ipAddress != nil,
              address.udpPort != nil else {
            return false
        }
        return address.protocols.contains(where: {
            if case .webrtcDirect = $0 { return true }
            return false
        })
    }

    // MARK: - SecuredTransport

    /// Dials a WebRTC Direct address and returns a secured, multiplexed connection.
    ///
    /// Generates a libp2p certificate (X.509 with OID 1.3.6.1.4.1.53594.1.1)
    /// for mutual authentication during the DTLS handshake.
    ///
    /// The remote PeerID is initially set to a placeholder. Once the DTLS
    /// handshake completes and the remote certificate is available, call
    /// `WebRTCMuxedConnection.tryExtractRemotePeerID()` to update it.
    public func dialSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any MuxedConnection {
        guard let components = extractWebRTCComponents(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }

        // Generate a certificate with the libp2p extension (OID 1.3.6.1.4.1.53594.1.1)
        let generated = try LibP2PCertificate.generate(keyPair: localKeyPair)
        let certificate = try DTLSCertificate(
            derEncoded: generated.certificateDER,
            privateKey: generated.privateKey
        )
        let endpoint = WebRTCEndpoint(certificate: certificate)

        // sendHandler requires UDP socket integration.
        // This is provided by P2P.addTransport() which owns the UDP socket.
        let connection = try endpoint.connect(
            remoteFingerprint: components.fingerprint,
            sendHandler: { _ in
                preconditionFailure(
                    "WebRTCTransport.dialSecured: sendHandler not configured. " +
                    "UDP I/O must be provided by the integration layer."
                )
            }
        )

        try connection.start()

        return WebRTCMuxedConnection(
            webrtcConnection: connection,
            localPeer: localKeyPair.peerID,
            remotePeer: localKeyPair.peerID, // Updated via tryExtractRemotePeerID() after DTLS handshake
            localAddress: nil,
            remoteAddress: address
        )
    }

    /// Listens on a WebRTC Direct address.
    ///
    /// Generates a libp2p certificate (X.509 with OID 1.3.6.1.4.1.53594.1.1)
    /// for mutual authentication during DTLS handshakes with connecting peers.
    public func listenSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any SecuredListener {
        guard canListen(address) else {
            throw TransportError.unsupportedAddress(address)
        }

        // Generate a certificate with the libp2p extension (OID 1.3.6.1.4.1.53594.1.1)
        let generated = try LibP2PCertificate.generate(keyPair: localKeyPair)
        let certificate = try DTLSCertificate(
            derEncoded: generated.certificateDER,
            privateKey: generated.privateKey
        )
        let endpoint = WebRTCEndpoint(certificate: certificate)
        let listener = try endpoint.listen()

        let certhash = certificate.fingerprint.multihash
        let localAddress = Multiaddr.webrtcDirect(
            host: address.ipAddress ?? "0.0.0.0",
            port: address.udpPort ?? 0,
            certhash: certhash
        )

        let securedListener = WebRTCSecuredListener(
            listener: listener,
            localAddress: localAddress,
            localKeyPair: localKeyPair
        )
        securedListener.startAccepting()

        return securedListener
    }

    // MARK: - Private

    private struct WebRTCAddressComponents {
        let host: String
        let port: UInt16
        let fingerprint: CertificateFingerprint
    }

    private func extractWebRTCComponents(from address: Multiaddr) -> WebRTCAddressComponents? {
        guard let ip = address.ipAddress,
              let port = address.udpPort else {
            return nil
        }

        var hasWebRTC = false
        var certhashData: Data?

        for proto in address.protocols {
            switch proto {
            case .webrtcDirect:
                hasWebRTC = true
            case .certhash(let data):
                certhashData = data
            default:
                break
            }
        }

        guard hasWebRTC else { return nil }

        // Parse certhash as multihash to get fingerprint
        let fingerprint: CertificateFingerprint
        if let hash = certhashData, hash.count >= 2 {
            // Multihash format: [hash function code, digest size, ...digest bytes]
            // The digest bytes are already the SHA-256 hash — use fromDigest
            // to avoid hash-of-hash.
            let digestStart = 2
            guard hash.count >= digestStart else { return nil }
            let digestBytes = Data(hash[digestStart...])
            fingerprint = CertificateFingerprint.fromDigest(digestBytes)
        } else {
            // No certhash — still valid for dialing (will verify after handshake)
            fingerprint = CertificateFingerprint.fromDER(Data())
        }

        return WebRTCAddressComponents(host: ip, port: port, fingerprint: fingerprint)
    }
}

// MARK: - Errors

/// Errors specific to WebRTC transport operations.
public enum WebRTCTransportError: Error, Sendable {
    case invalidAddress(Multiaddr)
    case dtlsHandshakeFailed(underlying: Error)
    case certificateInvalid(String)
    case peerIDMismatch(expected: PeerID, actual: PeerID)
    case connectionClosed
    case handshakeTimeout
}
