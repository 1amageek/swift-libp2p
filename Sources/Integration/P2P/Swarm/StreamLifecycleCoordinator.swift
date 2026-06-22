import P2PCore
import P2PMux
import P2PNegotiation
import P2PRuntime
import P2PProtocols

private let streamLifecycleLogger = Logger(label: "p2p.swarm.stream-lifecycle")

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
    private let resources: any StreamResourceAccounting

    init(resources: any StreamResourceAccounting) {
        self.resources = resources
    }

    func openOutboundStream(
        on connection: MuxedConnection,
        peer: PeerID,
        protocolID: String
    ) async throws -> MuxedStream {
        // Reserve the outbound stream against the protocol scope: the protocol
        // ID is known up front for an outbound dial, so per-protocol limits are
        // enforced here (not just peer/system).
        do {
            try resources.reserveStream(protocolID: protocolID, peer: peer, direction: .outbound)
        } catch let error as ResourceError {
            switch error {
            case .limitExceeded(let scope, let resource):
                throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
            }
        }

        let stream: MuxedStream
        do {
            stream = try await connection.newStream()
        } catch {
            resources.releaseStream(protocolID: protocolID, peer: peer, direction: .outbound)
            throw error
        }

        let reader = BufferedStreamReader(stream: stream)
        let result: NegotiationResult
        do {
            result = try await MultistreamSelect.negotiate(
                protocols: [protocolID],
                read: { try await reader.readMessage() },
                write: { try await stream.write($0) }
            )
        } catch {
            resources.releaseStream(protocolID: protocolID, peer: peer, direction: .outbound)
            do {
                try await stream.close()
            } catch let closeError {
                streamLifecycleLogger.error("Failed to close outbound stream after negotiation failure: \(closeError)")
                assertionFailure("DefaultStreamLifecycleCoordinator failed to close outbound stream after negotiation failure: \(closeError)")
            }
            throw error
        }

        guard result.protocolID == protocolID else {
            resources.releaseStream(protocolID: protocolID, peer: peer, direction: .outbound)
            do {
                try await stream.close()
            } catch let closeError {
                streamLifecycleLogger.error("Failed to close outbound stream after protocol mismatch: \(closeError)")
                assertionFailure("DefaultStreamLifecycleCoordinator failed to close outbound stream after protocol mismatch: \(closeError)")
            }
            throw NodeError.protocolNegotiationFailed
        }

        let negotiatedStream = bufferedStream(
            base: stream,
            remainder: combined(result.remainderBuffer, reader.drainRemainder())
        )
        return ResourceTrackedStream(
            stream: negotiatedStream,
            peer: peer,
            direction: .outbound,
            resourceManager: resources,
            negotiatedProtocolID: protocolID
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
            write: { try await stream.write($0) }
        )

        let negotiatedStream = bufferedStream(
            base: stream,
            remainder: combined(result.remainderBuffer, reader.drainRemainder())
        )
        return StreamContext(
            stream: negotiatedStream,
            remotePeer: remotePeer,
            remoteAddress: remoteAddress,
            localPeer: localPeer,
            localAddress: localAddress,
            protocolID: result.protocolID
        )
    }

    private func bufferedStream(base: MuxedStream, remainder: ByteBuffer) -> MuxedStream {
        if remainder.readableBytes == 0 {
            return base
        }
        return BufferedMuxedStream(stream: base, initialBuffer: remainder)
    }

    private func combined(_ left: ByteBuffer, _ right: ByteBuffer) -> ByteBuffer {
        if left.readableBytes == 0 {
            return right
        }
        if right.readableBytes == 0 {
            return left
        }

        var combined = left
        var tail = right
        combined.writeBuffer(&tail)
        return combined
    }
}
