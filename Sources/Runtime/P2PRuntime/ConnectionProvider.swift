import Foundation
import Synchronization
import P2PCore
import P2PSecurity
import P2PTransport
import P2PMux

public struct LocalIdentity: Sendable {
    public let keyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.keyPair = keyPair
    }

    public var peerID: PeerID {
        keyPair.peerID
    }
}

public protocol InboundSessionCandidate: Sendable {
    var remoteAddress: Multiaddr { get }
    func reject() async
    func establish() async throws -> any StreamSession
}

public protocol ConnectionAcceptor: Sendable {
    var localAddress: Multiaddr { get }
    func accept() async throws -> any InboundSessionCandidate
    func close() async throws
}

public protocol ConnectionProvider: Sendable {
    var pathKind: TransportPathKind { get }
    func canDial(_ address: Multiaddr) -> Bool
    func canListen(_ address: Multiaddr) -> Bool
    func dial(_ address: Multiaddr, identity: LocalIdentity) async throws -> any StreamSession
    func listen(_ address: Multiaddr, identity: LocalIdentity) async throws -> any ConnectionAcceptor
}

public enum ConnectionProviders {
    public static func compose(
        transports: [any Transport],
        security: [any SecurityUpgrader],
        muxers: [any Muxer]
    ) -> [any ConnectionProvider] {
        let upgrader = NegotiatingUpgrader(
            security: security,
            muxers: muxers
        )

        return transports.map { transport in
            if let securedTransport = transport as? any SecuredTransport {
                return SecuredTransportConnectionProvider(transport: securedTransport)
            }

            return PipelineConnectionProvider(
                transport: transport,
                upgrader: upgrader
            )
        }
    }

    public static func secured(_ transport: any SecuredTransport) -> any ConnectionProvider {
        SecuredTransportConnectionProvider(transport: transport)
    }

    public static func pipeline(
        transport: any Transport,
        security: [any SecurityUpgrader],
        muxers: [any Muxer]
    ) -> any ConnectionProvider {
        let upgrader = NegotiatingUpgrader(
            security: security,
            muxers: muxers
        )
        return PipelineConnectionProvider(
            transport: transport,
            upgrader: upgrader
        )
    }

    public static func pipeline(
        transport: any Transport,
        upgrader: any ConnectionUpgrader
    ) -> any ConnectionProvider {
        PipelineConnectionProvider(
            transport: transport,
            upgrader: upgrader
        )
    }
}

public enum ConnectionAcceptorError: Error {
    case establishFailed(any Error)
}

public struct SecuredTransportConnectionProvider: ConnectionProvider {
    public let transport: any SecuredTransport

    public init(transport: any SecuredTransport) {
        self.transport = transport
    }

    public var pathKind: TransportPathKind { transport.pathKind }

    public func canDial(_ address: Multiaddr) -> Bool {
        transport.canDial(address)
    }

    public func canListen(_ address: Multiaddr) -> Bool {
        transport.canListen(address)
    }

    public func dial(_ address: Multiaddr, identity: LocalIdentity) async throws -> any StreamSession {
        try await transport.dialSecured(address, localKeyPair: identity.keyPair)
    }

    public func listen(_ address: Multiaddr, identity: LocalIdentity) async throws -> any ConnectionAcceptor {
        let listener = try await transport.listenSecured(address, localKeyPair: identity.keyPair)
        return NativeConnectionAcceptor(listener: listener)
    }
}

public struct PipelineConnectionProvider: ConnectionProvider {
    public let transport: any Transport
    public let upgrader: any ConnectionUpgrader

    public init(
        transport: any Transport,
        upgrader: any ConnectionUpgrader
    ) {
        self.transport = transport
        self.upgrader = upgrader
    }

    public var pathKind: TransportPathKind { transport.pathKind }

    public func canDial(_ address: Multiaddr) -> Bool {
        transport.canDial(address)
    }

    public func canListen(_ address: Multiaddr) -> Bool {
        transport.canListen(address)
    }

    public func dial(_ address: Multiaddr, identity: LocalIdentity) async throws -> any StreamSession {
        let rawConnection = try await transport.dial(address)

        do {
            let result = try await upgrader.upgrade(
                rawConnection,
                localKeyPair: identity.keyPair,
                role: .initiator,
                expectedPeer: address.peerID
            )
            return result.connection
        } catch {
            do {
                try await rawConnection.close()
            } catch {}
            throw error
        }
    }

    public func listen(_ address: Multiaddr, identity: LocalIdentity) async throws -> any ConnectionAcceptor {
        let listener = try await transport.listen(address)
        return UpgradedConnectionAcceptor(
            listener: listener,
            upgrader: upgrader,
            identity: identity
        )
    }
}

private struct NativeInboundSessionCandidate: InboundSessionCandidate {
    let connection: any StreamSession

    var remoteAddress: Multiaddr {
        connection.remoteAddress
    }

    func reject() async {
        do {
            try await connection.close()
        } catch {}
    }

    func establish() async throws -> any StreamSession {
        connection
    }
}

private struct UpgradedInboundSessionCandidate: InboundSessionCandidate {
    let rawConnection: any RawConnection
    let upgrader: any ConnectionUpgrader
    let identity: LocalIdentity

    var remoteAddress: Multiaddr {
        rawConnection.remoteAddress
    }

    func reject() async {
        do {
            try await rawConnection.close()
        } catch {}
    }

    func establish() async throws -> any StreamSession {
        do {
            let result = try await upgrader.upgrade(
                rawConnection,
                localKeyPair: identity.keyPair,
                role: .responder,
                expectedPeer: nil
            )
            return result.connection
        } catch {
            do {
                try await rawConnection.close()
            } catch {}
            throw ConnectionAcceptorError.establishFailed(error)
        }
    }
}

private final class UpgradedConnectionAcceptor: ConnectionAcceptor {
    let localAddress: Multiaddr

    private let listener: any Listener
    private let upgrader: any ConnectionUpgrader
    private let identity: LocalIdentity

    init(
        listener: any Listener,
        upgrader: any ConnectionUpgrader,
        identity: LocalIdentity
    ) {
        self.localAddress = listener.localAddress
        self.listener = listener
        self.upgrader = upgrader
        self.identity = identity
    }

    func accept() async throws -> any InboundSessionCandidate {
        let rawConnection = try await listener.accept()
        return UpgradedInboundSessionCandidate(
            rawConnection: rawConnection,
            upgrader: upgrader,
            identity: identity
        )
    }

    func close() async throws {
        try await listener.close()
    }
}

private final class NativeConnectionAcceptor: ConnectionAcceptor {
    let localAddress: Multiaddr

    private struct State: Sendable {
        var pending: [any InboundSessionCandidate] = []
        var waiters: [CheckedContinuation<any InboundSessionCandidate, Error>] = []
        var isClosed = false
        var forwardTask: Task<Void, Never>?
    }

    private let listener: any SecuredListener
    private let state = Mutex(State())

    init(listener: any SecuredListener) {
        self.localAddress = listener.localAddress
        self.listener = listener

        let task = Task { [weak self] in
            guard let self else { return }
            for await connection in listener.connections {
                let candidate: any InboundSessionCandidate = NativeInboundSessionCandidate(connection: connection)
                let waiter = self.state.withLock { s -> CheckedContinuation<any InboundSessionCandidate, Error>? in
                    guard !s.isClosed else { return nil }
                    if !s.waiters.isEmpty {
                        return s.waiters.removeFirst()
                    }
                    s.pending.append(candidate)
                    return nil
                }
                waiter?.resume(returning: candidate)
            }

            let waiters = self.state.withLock { s -> [CheckedContinuation<any InboundSessionCandidate, Error>] in
                s.isClosed = true
                let waiters = s.waiters
                s.waiters.removeAll()
                s.pending.removeAll()
                s.forwardTask = nil
                return waiters
            }

            for waiter in waiters {
                waiter.resume(throwing: TransportError.listenerClosed)
            }
        }

        state.withLock { $0.forwardTask = task }
    }

    func accept() async throws -> any InboundSessionCandidate {
        let pending = state.withLock { s -> (any InboundSessionCandidate)? in
            if !s.pending.isEmpty {
                return s.pending.removeFirst()
            }
            if s.isClosed {
                return nil
            }
            return nil
        }

        if let pending {
            return pending
        }

        return try await withCheckedThrowingContinuation { continuation in
            let action = state.withLock { s -> ((CheckedContinuation<any InboundSessionCandidate, Error>) -> Void)? in
                if !s.pending.isEmpty {
                    let pending = s.pending.removeFirst()
                    return { $0.resume(returning: pending) }
                }
                if s.isClosed {
                    return { $0.resume(throwing: TransportError.listenerClosed) }
                }
                s.waiters.append(continuation)
                return nil
            }
            action?(continuation)
        }
    }

    func close() async throws {
        let (task, waiters) = state.withLock { s -> (Task<Void, Never>?, [CheckedContinuation<any InboundSessionCandidate, Error>]) in
            guard !s.isClosed else { return (nil, []) }
            s.isClosed = true
            let task = s.forwardTask
            s.forwardTask = nil
            let waiters = s.waiters
            s.waiters.removeAll()
            s.pending.removeAll()
            return (task, waiters)
        }

        task?.cancel()
        for waiter in waiters {
            waiter.resume(throwing: TransportError.listenerClosed)
        }
        try await listener.close()
    }
}
