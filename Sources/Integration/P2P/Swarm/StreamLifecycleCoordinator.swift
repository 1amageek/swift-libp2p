import P2PCore
import P2PMux
import P2PNegotiation
import P2PRuntime
import P2PProtocols

internal protocol StreamLifecycleCoordinator: Sendable {
    func openOutboundStream(
        on connection: MuxedConnection,
        peer: PeerID,
        protocolID: String
    ) async throws -> MuxedStream

    func negotiateInboundStream(
        _ stream: MuxedStream,
        supportedProtocols: [String],
        remotePeer: PeerID,
        remoteAddress: Multiaddr,
        localPeer: PeerID,
        localAddress: Multiaddr?
    ) async throws -> StreamContext?
}

internal struct DefaultStreamLifecycleCoordinator: StreamLifecycleCoordinator {
    private let resources: (any StreamResourceAccounting)?

    init(resources: (any StreamResourceAccounting)?) {
        self.resources = resources
    }

    func openOutboundStream(
        on connection: MuxedConnection,
        peer: PeerID,
        protocolID: String
    ) async throws -> MuxedStream {
        if let resources {
            do {
                try resources.reserveStream(peer: peer, direction: .outbound)
            } catch let error as ResourceError {
                switch error {
                case .limitExceeded(let scope, let resource):
                    throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                }
            }
        }

        let stream: MuxedStream
        do {
            stream = try await connection.newStream()
        } catch {
            resources?.releaseStream(peer: peer, direction: .outbound)
            throw error
        }

        let reader = BufferedStreamReader(stream: stream)
        let result: NegotiationResult
        do {
            result = try await MultistreamSelect.negotiate(
                protocols: [protocolID],
                read: { try await reader.readMessage() },
                write: { try await stream.write(ByteBuffer(bytes: $0)) }
            )
        } catch {
            resources?.releaseStream(peer: peer, direction: .outbound)
            do {
                try await stream.close()
            } catch {}
            throw error
        }

        guard result.protocolID == protocolID else {
            resources?.releaseStream(peer: peer, direction: .outbound)
            do {
                try await stream.close()
            } catch {}
            throw NodeError.protocolNegotiationFailed
        }

        let negotiatedStream = bufferedStream(base: stream, remainder: result.remainder + reader.drainRemainder())
        guard let resources else {
            return negotiatedStream
        }
        return ResourceTrackedStream(
            stream: negotiatedStream,
            peer: peer,
            direction: .outbound,
            resourceManager: resources
        )
    }

    func negotiateInboundStream(
        _ stream: MuxedStream,
        supportedProtocols: [String],
        remotePeer: PeerID,
        remoteAddress: Multiaddr,
        localPeer: PeerID,
        localAddress: Multiaddr?
    ) async throws -> StreamContext? {
        let reader = BufferedStreamReader(stream: stream)
        let result = try await MultistreamSelect.handle(
            supported: supportedProtocols,
            read: { try await reader.readMessage() },
            write: { try await stream.write(ByteBuffer(bytes: $0)) }
        )

        let negotiatedStream = bufferedStream(base: stream, remainder: result.remainder + reader.drainRemainder())
        return StreamContext(
            stream: negotiatedStream,
            remotePeer: remotePeer,
            remoteAddress: remoteAddress,
            localPeer: localPeer,
            localAddress: localAddress,
            protocolID: result.protocolID
        )
    }

    private func bufferedStream(base: MuxedStream, remainder: Data) -> MuxedStream {
        if remainder.isEmpty {
            return base
        }
        return BufferedMuxedStream(stream: base, initialBuffer: remainder)
    }
}
