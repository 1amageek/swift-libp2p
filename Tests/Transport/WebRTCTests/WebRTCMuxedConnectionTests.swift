/// Tests for WebRTCMuxedConnection
///
/// Verifies updateRemotePeer, updateRemoteAddress, and close behavior.

import Testing
import Foundation
@testable import P2PTransportWebRTC
@testable import P2PCore
@testable import P2PTransport
@testable import WebRTC
@testable import DTLSCore

@Suite("WebRTC MuxedConnection Tests")
struct WebRTCMuxedConnectionTests {

    /// Helper to create a test muxed connection.
    private func createTestConnection() throws -> (WebRTCMuxedConnection, PeerID, PeerID) {
        let cert = try DTLSCertificate.generateSelfSigned()
        let webrtcConn = WebRTCConnection.asServer(
            certificate: cert,
            sendHandler: { _ in }
        )
        let localPeer = KeyPair.generateEd25519().peerID
        let remotePeer = KeyPair.generateEd25519().peerID
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4001/webrtc-direct")

        let muxed = WebRTCMuxedConnection(
            webrtcConnection: webrtcConn,
            localPeer: localPeer,
            remotePeer: remotePeer,
            localAddress: addr,
            remoteAddress: addr
        )

        return (muxed, localPeer, remotePeer)
    }

    @Test("updateRemotePeer changes remotePeer")
    func updateRemotePeerChangesValue() throws {
        let (muxed, _, originalRemote) = try createTestConnection()

        #expect(muxed.remotePeer == originalRemote)

        let newRemote = KeyPair.generateEd25519().peerID
        muxed.updateRemotePeer(newRemote)

        #expect(muxed.remotePeer == newRemote)
        #expect(muxed.remotePeer != originalRemote)
    }

    @Test("updateRemoteAddress changes remoteAddress")
    func updateRemoteAddressChangesValue() throws {
        let (muxed, _, _) = try createTestConnection()

        let originalAddress = muxed.remoteAddress
        let newAddress = try Multiaddr("/ip4/10.0.0.1/udp/5000/webrtc-direct")
        muxed.updateRemoteAddress(newAddress)

        #expect(muxed.remoteAddress == newAddress)
        #expect(muxed.remoteAddress != originalAddress)
    }

    @Test("close prevents new streams", .timeLimit(.minutes(1)))
    func closeSetsClosed() async throws {
        let (muxed, _, _) = try createTestConnection()

        try await muxed.close()

        await #expect(throws: TransportError.self) {
            _ = try await muxed.newStream()
        }
    }
}
