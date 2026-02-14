import Foundation
import Synchronization
import P2PCore
import P2PTransport
import P2PMux
import QUIC

/// A secured listener for WebTransport connections.
public final class WebTransportSecuredListener: SecuredListener, Sendable {
    private let endpoint: QUICEndpoint
    private let endpointTask: Task<Void, Error>
    private let localSocketAddress: QUIC.SocketAddress
    private let localKeyPair: KeyPair
    private let configuration: WebTransportConfiguration
    private let certificateStore: WebTransportCertificateStore

    private struct State: Sendable {
        var isClosed = false
        var localAddress: Multiaddr
        var continuation: AsyncStream<any MuxedConnection>.Continuation?
        var forwardingTask: Task<Void, Never>?
        var rotationTask: Task<Void, Never>?
    }

    private let state: Mutex<State>

    public let connections: AsyncStream<any MuxedConnection>

    public var localAddress: Multiaddr {
        state.withLock { $0.localAddress }
    }

    public var localPeer: PeerID { localKeyPair.peerID }

    init(
        endpoint: QUICEndpoint,
        endpointTask: Task<Void, Error>,
        localSocketAddress: QUIC.SocketAddress,
        localAddress: Multiaddr,
        localKeyPair: KeyPair,
        configuration: WebTransportConfiguration,
        certificateStore: WebTransportCertificateStore
    ) {
        self.endpoint = endpoint
        self.endpointTask = endpointTask
        self.localSocketAddress = localSocketAddress
        self.localKeyPair = localKeyPair
        self.configuration = configuration
        self.certificateStore = certificateStore

        let (stream, continuation) = AsyncStream<any MuxedConnection>.makeStream()
        self.connections = stream
        self.state = Mutex(State(
            localAddress: localAddress,
            continuation: continuation
        ))
    }

    func startAccepting() {
        let rotationTask = Task { [weak self] in
            guard let self = self else { return }
            let pollInterval = self.rotationPollInterval()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    break
                }

                do {
                    try self.refreshLocalAddress()
                } catch {
                    continue
                }
            }
        }

        let task = Task { [weak self] in
            guard let self = self else { return }

            for await quicConnection in await self.endpoint.incomingConnections {
                let isClosed = self.state.withLock { $0.isClosed }
                if isClosed { break }

                do {
                    try await WebTransportQUICPeerExtractor.waitForHandshake(
                        quicConnection,
                        timeout: self.configuration.connectionTimeout
                    )
                    let peerInfo = try WebTransportQUICPeerExtractor.extract(from: quicConnection)

                    try await WebTransportSessionNegotiator.performServerNegotiation(
                        on: quicConnection,
                        timeout: self.configuration.connectionTimeout
                    )

                    let localAddress = try self.resolveLocalAddress(for: quicConnection)
                    let remoteLeaf = peerInfo.peerCertificates[0]
                    let remoteHash = WebTransportCertificateHash.multihashSHA256(for: remoteLeaf)

                    let connection = WebTransportMuxedConnection(
                        quicConnection: quicConnection,
                        localPeer: self.localKeyPair.peerID,
                        remotePeer: peerInfo.peerID,
                        localAddress: localAddress,
                        remoteCertificateHashes: [remoteHash]
                    )
                    connection.startForwarding()

                    let shouldContinue = self.state.withLock { state -> Bool in
                        guard !state.isClosed else { return false }
                        state.continuation?.yield(connection)
                        return true
                    }
                    if !shouldContinue { break }
                } catch {
                    await quicConnection.close(
                        applicationError: 0x100,
                        reason: "webtransport accept failed"
                    )
                }
            }

            self.state.withLock { state in
                state.continuation?.finish()
                state.continuation = nil
            }
        }

        state.withLock { state in
            state.forwardingTask = task
            state.rotationTask = rotationTask
        }
    }

    private func resolveLocalAddress(for connection: any QUICConnectionProtocol) throws -> Multiaddr {
        guard let localSocketAddress = connection.localAddress else {
            return localAddress
        }
        let hashes = try certificateStore.advertisedHashes()
        return WebTransportAddressBuilder.make(
            socketAddress: localSocketAddress,
            certificateHashes: hashes,
            peerID: localKeyPair.peerID
        )
    }

    private func refreshLocalAddress() throws {
        let hashes = try certificateStore.advertisedHashes()
        let updated = WebTransportAddressBuilder.make(
            socketAddress: localSocketAddress,
            certificateHashes: hashes,
            peerID: localKeyPair.peerID
        )
        state.withLock { $0.localAddress = updated }
    }

    private func rotationPollInterval() -> Duration {
        let oneSecond = Duration.seconds(1)
        if configuration.certRotationInterval < oneSecond {
            return oneSecond
        }
        let oneHour = Duration.seconds(3600)
        if configuration.certRotationInterval < oneHour {
            return configuration.certRotationInterval
        }
        return oneHour
    }

    public func close() async throws {
        let tasks = state.withLock { state -> (Task<Void, Never>?, Task<Void, Never>?) in
            state.isClosed = true
            state.continuation?.finish()
            state.continuation = nil
            let forwardingTask = state.forwardingTask
            state.forwardingTask = nil
            let rotationTask = state.rotationTask
            state.rotationTask = nil
            return (forwardingTask, rotationTask)
        }

        tasks.0?.cancel()
        tasks.1?.cancel()
        await endpoint.shutdown()
        do {
            _ = try await endpointTask.value
        } catch {
            // Endpoint task cancellation or stop-related errors are expected on close.
        }
    }
}
