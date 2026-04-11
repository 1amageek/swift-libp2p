/// ConnectionUpgrader - Encapsulates the connection upgrade pipeline
///
/// Handles the full upgrade sequence: Raw -> Secure -> Muxed
/// with multistream-select negotiation at each layer.

import Foundation
import P2PCore
import P2PSecurity
import P2PMux
import P2PNegotiation
import Synchronization

public struct UpgradeResult: Sendable {
    public let connection: MuxedConnection
    public let securityProtocol: String
    public let muxerProtocol: String

    public init(
        connection: MuxedConnection,
        securityProtocol: String,
        muxerProtocol: String
    ) {
        self.connection = connection
        self.securityProtocol = securityProtocol
        self.muxerProtocol = muxerProtocol
    }
}

private final class BufferedRawConnection: RawConnection, Sendable {
    private let underlying: any RawConnection
    private let buffer: Mutex<ByteBuffer>

    var localAddress: Multiaddr? { underlying.localAddress }
    var remoteAddress: Multiaddr { underlying.remoteAddress }

    init(underlying: any RawConnection, initialBuffer: Data = Data()) {
        self.underlying = underlying
        self.buffer = Mutex(ByteBuffer(bytes: initialBuffer))
    }

    func read() async throws -> ByteBuffer {
        let buffered = buffer.withLock { buf -> ByteBuffer? in
            if buf.readableBytes > 0 {
                let data = buf
                buf = ByteBuffer()
                return data
            }
            return nil
        }

        if let buffered {
            return buffered
        }

        return try await underlying.read()
    }

    func write(_ data: ByteBuffer) async throws {
        try await underlying.write(data)
    }

    func close() async throws {
        try await underlying.close()
    }
}

private final class BufferedSecuredConnection: SecuredConnection, Sendable {
    private let underlying: any SecuredConnection
    private let buffer: Mutex<ByteBuffer>

    var localPeer: PeerID { underlying.localPeer }
    var remotePeer: PeerID { underlying.remotePeer }
    var localAddress: Multiaddr? { underlying.localAddress }
    var remoteAddress: Multiaddr { underlying.remoteAddress }

    init(underlying: any SecuredConnection, initialBuffer: Data = Data()) {
        self.underlying = underlying
        self.buffer = Mutex(ByteBuffer(bytes: initialBuffer))
    }

    func read() async throws -> ByteBuffer {
        let buffered = buffer.withLock { buf -> ByteBuffer? in
            if buf.readableBytes > 0 {
                let data = buf
                buf = ByteBuffer()
                return data
            }
            return nil
        }

        if let buffered {
            return buffered
        }

        return try await underlying.read()
    }

    func write(_ data: ByteBuffer) async throws {
        try await underlying.write(data)
    }

    func close() async throws {
        try await underlying.close()
    }
}

public protocol ConnectionUpgrader: Sendable {
    func upgrade(
        _ raw: any RawConnection,
        localKeyPair: KeyPair,
        role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> UpgradeResult
}

public final class NegotiatingUpgrader: ConnectionUpgrader, Sendable {
    private let securityUpgraders: [any SecurityUpgrader]
    private let muxers: [any Muxer]
    private static let maxMessageSize = 64 * 1024

    public init(security: [any SecurityUpgrader], muxers: [any Muxer]) {
        self.securityUpgraders = security
        self.muxers = muxers
    }

    public func upgrade(
        _ raw: any RawConnection,
        localKeyPair: KeyPair,
        role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> UpgradeResult {
        do {
            let muxerProtocolIDs = muxers.map(\.protocolID)
            let (secured, securityProtocol, earlyMuxer) = try await upgradeToSecured(
                raw,
                localKeyPair: localKeyPair,
                role: role,
                expectedPeer: expectedPeer,
                muxerProtocols: muxerProtocolIDs
            )

            let (muxed, muxerProtocol): (MuxedConnection, String)
            if let earlyMuxer,
               let muxer = muxers.first(where: { $0.protocolID == earlyMuxer }) {
                let muxedConn = try await muxer.multiplex(secured, isInitiator: role == .initiator)
                (muxed, muxerProtocol) = (muxedConn, earlyMuxer)
            } else {
                (muxed, muxerProtocol) = try await upgradeToMuxed(secured, role: role)
            }

            return UpgradeResult(
                connection: muxed,
                securityProtocol: securityProtocol,
                muxerProtocol: muxerProtocol
            )
        } catch let error as NegotiationError {
            switch error {
            case .messageTooLarge(let size, let max):
                throw UpgradeError.messageTooLarge(size: size, max: max)
            default:
                throw error
            }
        } catch let error as VarintError {
            switch error {
            case .insufficientData:
                throw error
            case .overflow, .valueExceedsIntMax:
                throw UpgradeError.invalidVarint
            }
        }
    }

    private func upgradeToSecured(
        _ raw: any RawConnection,
        localKeyPair: KeyPair,
        role: SecurityRole,
        expectedPeer: PeerID?,
        muxerProtocols: [String]
    ) async throws -> (any SecuredConnection, String, String?) {
        let protocolIDs = securityUpgraders.map(\.protocolID)

        guard !protocolIDs.isEmpty else {
            throw UpgradeError.noSecurityUpgraders
        }

        var buffer = Data()

        let negotiatedProtocol: String
        if role == .initiator {
            let result = try await MultistreamSelect.negotiateLazy(
                protocols: protocolIDs,
                read: { try await self.readBuffered(from: raw, buffer: &buffer) },
                write: { try await raw.write(ByteBuffer(bytes: $0)) }
            )
            negotiatedProtocol = result.protocolID
        } else {
            let result = try await MultistreamSelect.handle(
                supported: protocolIDs,
                read: { try await self.readBuffered(from: raw, buffer: &buffer) },
                write: { try await raw.write(ByteBuffer(bytes: $0)) }
            )
            negotiatedProtocol = result.protocolID
        }

        guard let upgrader = securityUpgraders.first(where: { $0.protocolID == negotiatedProtocol }) else {
            throw UpgradeError.securityNegotiationFailed(negotiatedProtocol)
        }

        let bufferedRaw = BufferedRawConnection(underlying: raw, initialBuffer: buffer)

        if let earlyMuxerUpgrader = upgrader as? EarlyMuxerNegotiating,
           !muxerProtocols.isEmpty {
            let (secured, negotiatedMuxer) = try await earlyMuxerUpgrader.secureWithEarlyMuxer(
                bufferedRaw,
                localKeyPair: localKeyPair,
                as: role,
                expectedPeer: expectedPeer,
                muxerProtocols: muxerProtocols
            )
            return (secured, negotiatedProtocol, negotiatedMuxer)
        }

        let secured = try await upgrader.secure(
            bufferedRaw,
            localKeyPair: localKeyPair,
            as: role,
            expectedPeer: expectedPeer
        )

        return (secured, negotiatedProtocol, nil)
    }

    private func upgradeToMuxed(
        _ secured: any SecuredConnection,
        role: SecurityRole
    ) async throws -> (MuxedConnection, String) {
        let protocolIDs = muxers.map(\.protocolID)

        guard !protocolIDs.isEmpty else {
            throw UpgradeError.noMuxers
        }

        var buffer = Data()

        let negotiatedProtocol: String
        if role == .initiator {
            let result = try await MultistreamSelect.negotiateLazy(
                protocols: protocolIDs,
                read: { try await self.readBuffered(from: secured, buffer: &buffer) },
                write: { try await secured.write(ByteBuffer(bytes: $0)) }
            )
            negotiatedProtocol = result.protocolID
        } else {
            let result = try await MultistreamSelect.handle(
                supported: protocolIDs,
                read: { try await self.readBuffered(from: secured, buffer: &buffer) },
                write: { try await secured.write(ByteBuffer(bytes: $0)) }
            )
            negotiatedProtocol = result.protocolID
        }

        guard let muxer = muxers.first(where: { $0.protocolID == negotiatedProtocol }) else {
            throw UpgradeError.muxerNegotiationFailed(negotiatedProtocol)
        }

        let bufferedSecured = BufferedSecuredConnection(underlying: secured, initialBuffer: buffer)
        let muxed = try await muxer.multiplex(bufferedSecured, isInitiator: role == .initiator)
        return (muxed, negotiatedProtocol)
    }

    private func readBuffered(
        from raw: any RawConnection,
        buffer: inout Data
    ) async throws -> Data {
        if !buffer.isEmpty {
            let data = buffer
            buffer = Data()
            return data
        }

        let chunk = try await raw.read()
        if chunk.readableBytes == 0 {
            throw UpgradeError.connectionClosed
        }
        return Data(buffer: chunk)
    }

    private func readBuffered(
        from secured: any SecuredConnection,
        buffer: inout Data
    ) async throws -> Data {
        if !buffer.isEmpty {
            let data = buffer
            buffer = Data()
            return data
        }

        let chunk = try await secured.read()
        if chunk.readableBytes == 0 {
            throw UpgradeError.connectionClosed
        }
        return Data(buffer: chunk)
    }
}

public enum UpgradeError: Error, Sendable {
    case noSecurityUpgraders
    case noMuxers
    case securityNegotiationFailed(String)
    case muxerNegotiationFailed(String)
    case connectionClosed
    case messageTooLarge(size: Int, max: Int)
    case invalidVarint
}
