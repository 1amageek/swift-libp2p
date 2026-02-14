import Foundation
import P2PCore
import P2PTransportQUIC
import QUIC

struct WebTransportPeerInfo: Sendable {
    let peerID: PeerID
    let peerCertificates: [Data]
}

enum WebTransportQUICPeerExtractor {
    static func waitForHandshake(
        _ connection: any QUICConnectionProtocol,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WebTransportError.timeout
            }

            group.addTask {
                while !connection.isEstablished {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                }
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    static func extract(from connection: any QUICConnectionProtocol) throws -> WebTransportPeerInfo {
        guard let managedConnection = connection as? ManagedConnection else {
            throw WebTransportError.connectionFailed("Unexpected QUIC connection type")
        }

        guard let tlsProvider = managedConnection.underlyingTLSProvider as? SwiftQUICTLSProvider else {
            throw WebTransportError.connectionFailed("Unexpected TLS provider type")
        }

        guard tlsProvider.negotiatedALPN == WebTransportProtocol.alpn else {
            throw WebTransportError.connectionFailed("ALPN mismatch")
        }

        guard let peerID = tlsProvider.remotePeerID else {
            throw WebTransportError.connectionFailed("Remote PeerID not available after handshake")
        }

        guard let certificates = tlsProvider.peerCertificates, let _ = certificates.first else {
            throw WebTransportError.connectionFailed("Peer certificate chain is unavailable")
        }

        return WebTransportPeerInfo(peerID: peerID, peerCertificates: certificates)
    }
}

enum WebTransportAddressBuilder {
    static func make(
        socketAddress: QUIC.SocketAddress,
        certificateHashes: [Data],
        peerID: PeerID?
    ) -> Multiaddr {
        WebTransportAddressComponents(
            host: socketAddress.ipAddress.contains(":")
                ? .ip6(socketAddress.ipAddress)
                : .ip4(socketAddress.ipAddress),
            port: socketAddress.port,
            certificateHashes: certificateHashes,
            peerID: peerID
        ).toMultiaddr()
    }
}
