import Foundation
import Synchronization
import P2PCore
import P2PTransport
import P2PTransportSecured
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
        var nextActiveConnectionID: UInt64 = 0
        var activeConnections: [ActiveConnection] = []
    }

    private struct ActiveConnection: Sendable {
        let id: UInt64
        let connection: any QUICConnectionProtocol
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
                let activeConnectionID: UInt64? = self.state.withLock { state in
                    guard !state.isClosed else { return nil }
                    let id = state.nextActiveConnectionID
                    state.nextActiveConnectionID += 1
                    state.activeConnections.append(ActiveConnection(id: id, connection: quicConnection))
                    return id
                }
                guard let activeConnectionID else { break }

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
                        remoteCertificateHashes: [remoteHash],
                        onClose: { [weak self] in
                            self?.removeActiveConnection(id: activeConnectionID)
                        }
                    )
                    connection.startForwarding()

                    let continuation = self.state.withLock { state -> AsyncStream<any MuxedConnection>.Continuation? in
                        guard !state.isClosed else { return nil }
                        return state.continuation
                    }
                    guard let continuation else {
                        do {
                            try await connection.close()
                        } catch {
                            // The underlying QUIC connection is being torn down anyway.
                        }
                        break
                    }
                    guard case .enqueued = continuation.yield(connection) else {
                        do {
                            try await connection.close()
                        } catch {
                            // The underlying QUIC connection is being torn down anyway.
                        }
                        continue
                    }
                } catch {
                    self.removeActiveConnection(id: activeConnectionID)
                    await quicConnection.close(
                        applicationError: 0x100,
                        reason: "webtransport accept failed"
                    )
                }
            }

            let continuation = self.state.withLock { state -> AsyncStream<any MuxedConnection>.Continuation? in
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.finish()
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

    private func removeActiveConnection(id: UInt64) {
        state.withLock { state in
            state.activeConnections.removeAll { $0.id == id }
        }
    }

    public func close() async throws {
        let cleanup = state.withLock { state -> (
            Task<Void, Never>?,
            Task<Void, Never>?,
            AsyncStream<any MuxedConnection>.Continuation?,
            [ActiveConnection]
        ) in
            state.isClosed = true
            let continuation = state.continuation
            state.continuation = nil
            let forwardingTask = state.forwardingTask
            state.forwardingTask = nil
            let rotationTask = state.rotationTask
            state.rotationTask = nil
            let activeConnections = state.activeConnections
            state.activeConnections.removeAll()
            return (forwardingTask, rotationTask, continuation, activeConnections)
        }

        cleanup.2?.finish()
        cleanup.0?.cancel()
        cleanup.1?.cancel()
        await cleanup.1?.value
        for entry in cleanup.3 {
            await entry.connection.close(error: nil)
        }
        var shutdownError: Error?
        do {
            try await endpoint.shutdown()
        } catch {
            shutdownError = error
        }
        do {
            _ = try await endpointTask.value
        } catch {
            // Endpoint task cancellation or stop-related errors are expected on close.
        }
        await cleanup.0?.value
        if let shutdownError {
            throw shutdownError
        }
    }
}
