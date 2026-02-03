/// ConnectionUpgrader - Encapsulates the connection upgrade pipeline
///
/// Handles the full upgrade sequence: Raw → Secured → Muxed
/// with multistream-select negotiation at each layer.

import Foundation
import P2PCore
import P2PSecurity
import P2PMux
import P2PNegotiation
import Synchronization

/// Result of a connection upgrade.
public struct UpgradeResult: Sendable {
    /// The muxed connection.
    public let connection: MuxedConnection

    /// The security protocol that was negotiated.
    public let securityProtocol: String

    /// The muxer protocol that was negotiated.
    public let muxerProtocol: String
}

// MARK: - Buffered Connection Wrappers

/// A raw connection wrapper that preserves leftover data from multistream-select negotiation.
///
/// After multistream-select negotiation, there may be leftover data in the read buffer
/// that belongs to the next protocol layer (e.g., Noise handshake). This wrapper ensures
/// that data is not lost.
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
        // Return buffered data first if available
        let buffered = buffer.withLock { buf -> ByteBuffer? in
            if buf.readableBytes > 0 {
                let data = buf
                buf = ByteBuffer()
                return data
            }
            return nil
        }

        if let data = buffered {
            return data
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

/// A secured connection wrapper that preserves leftover data from multistream-select negotiation.
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
        // Return buffered data first if available
        let buffered = buffer.withLock { buf -> ByteBuffer? in
            if buf.readableBytes > 0 {
                let data = buf
                buf = ByteBuffer()
                return data
            }
            return nil
        }

        if let data = buffered {
            return data
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

/// Protocol for upgrading raw connections to muxed connections.
public protocol ConnectionUpgrader: Sendable {
    /// Upgrades a raw connection to a muxed connection.
    ///
    /// - Parameters:
    ///   - raw: The raw connection to upgrade
    ///   - localKeyPair: The local key pair for authentication
    ///   - role: Whether we are initiator or responder
    ///   - expectedPeer: Expected remote peer ID (optional, for verification)
    /// - Returns: The upgrade result containing the muxed connection and negotiated protocols
    func upgrade(
        _ raw: any RawConnection,
        localKeyPair: KeyPair,
        role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> UpgradeResult
}

/// Standard connection upgrader that uses multistream-select for negotiation.
public final class NegotiatingUpgrader: ConnectionUpgrader, Sendable {

    private let securityUpgraders: [any SecurityUpgrader]
    private let muxers: [any Muxer]

    /// Maximum message size for multistream-select (64KB should be plenty).
    private static let maxMessageSize = 64 * 1024

    /// Creates a new negotiating upgrader.
    ///
    /// - Parameters:
    ///   - security: Security upgraders in priority order
    ///   - muxers: Muxers in priority order
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
        // Phase 1: Negotiate and upgrade security (with early muxer negotiation if supported)
        let muxerProtocolIDs = muxers.map(\.protocolID)
        let (secured, securityProtocol, earlyMuxer) = try await upgradeToSecured(
            raw,
            localKeyPair: localKeyPair,
            role: role,
            expectedPeer: expectedPeer,
            muxerProtocols: muxerProtocolIDs
        )

        // Phase 2: Negotiate and upgrade muxer
        // If early muxer negotiation succeeded, skip multistream-select
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
    }

    // MARK: - Security Upgrade

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

        // Create buffered reader for raw connection
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

        // Find the matching upgrader
        guard let upgrader = securityUpgraders.first(where: { $0.protocolID == negotiatedProtocol }) else {
            throw UpgradeError.securityNegotiationFailed(negotiatedProtocol)
        }

        // Wrap the raw connection with any leftover buffer data.
        // This ensures the security upgrader sees any data that was read
        // ahead during multistream-select negotiation.
        let bufferedRaw = BufferedRawConnection(underlying: raw, initialBuffer: buffer)

        // Use early muxer negotiation if the security upgrader supports it
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

        // Standard security upgrade (no early muxer negotiation)
        let secured = try await upgrader.secure(
            bufferedRaw,
            localKeyPair: localKeyPair,
            as: role,
            expectedPeer: expectedPeer
        )

        return (secured, negotiatedProtocol, nil)
    }

    // MARK: - Muxer Upgrade

    private func upgradeToMuxed(
        _ secured: any SecuredConnection,
        role: SecurityRole
    ) async throws -> (MuxedConnection, String) {
        let protocolIDs = muxers.map(\.protocolID)

        guard !protocolIDs.isEmpty else {
            throw UpgradeError.noMuxers
        }

        // Create buffered reader for secured connection
        var buffer = Data()

        let negotiatedProtocol: String
        if role == .initiator {
            let result = try await MultistreamSelect.negotiateLazy(
                protocols: protocolIDs,
                read: { try await self.readBufferedSecured(from: secured, buffer: &buffer) },
                write: { try await secured.write(ByteBuffer(bytes: $0)) }
            )
            negotiatedProtocol = result.protocolID
        } else {
            let result = try await MultistreamSelect.handle(
                supported: protocolIDs,
                read: { try await self.readBufferedSecured(from: secured, buffer: &buffer) },
                write: { try await secured.write(ByteBuffer(bytes: $0)) }
            )
            negotiatedProtocol = result.protocolID
        }

        // Find the matching muxer
        guard let muxer = muxers.first(where: { $0.protocolID == negotiatedProtocol }) else {
            throw UpgradeError.muxerNegotiationFailed(negotiatedProtocol)
        }

        // Wrap the secured connection with any leftover buffer data.
        // This ensures the muxer sees any data that was read ahead
        // during multistream-select negotiation.
        let bufferedSecured = BufferedSecuredConnection(underlying: secured, initialBuffer: buffer)

        // Perform muxer upgrade with the buffered connection
        let muxed = try await muxer.multiplex(
            bufferedSecured,
            isInitiator: role == .initiator
        )

        return (muxed, negotiatedProtocol)
    }

    // MARK: - Buffered Reading

    /// Reads a complete multistream-select message from a raw connection.
    private func readBuffered(from raw: any RawConnection, buffer: inout Data) async throws -> Data {
        while true {
            if !buffer.isEmpty {
                if let message = try extractMessage(from: &buffer) {
                    return message
                }
            }

            // Check buffer size before reading more
            if buffer.count > Self.maxMessageSize {
                throw UpgradeError.messageTooLarge(size: buffer.count, max: Self.maxMessageSize)
            }

            let chunk = try await raw.read()
            if chunk.readableBytes == 0 {
                throw UpgradeError.connectionClosed
            }
            buffer.append(Data(buffer: chunk))
        }
    }

    /// Reads a complete multistream-select message from a secured connection.
    private func readBufferedSecured(from secured: any SecuredConnection, buffer: inout Data) async throws -> Data {
        while true {
            if !buffer.isEmpty {
                if let message = try extractMessage(from: &buffer) {
                    return message
                }
            }

            // Check buffer size before reading more
            if buffer.count > Self.maxMessageSize {
                throw UpgradeError.messageTooLarge(size: buffer.count, max: Self.maxMessageSize)
            }

            let chunk = try await secured.read()
            if chunk.readableBytes == 0 {
                throw UpgradeError.connectionClosed
            }
            buffer.append(Data(buffer: chunk))
        }
    }

    /// Extracts a complete length-prefixed message from the buffer.
    private func extractMessage(from buffer: inout Data) throws -> Data? {
        guard !buffer.isEmpty else { return nil }

        do {
            let (length, lengthBytes) = try Varint.decode(buffer)

            // Check for oversized message (Int.max check prevents crash on conversion)
            guard length <= UInt64(Self.maxMessageSize) else {
                throw UpgradeError.messageTooLarge(size: Int(min(length, UInt64(Int.max))), max: Self.maxMessageSize)
            }
            let messageLength = Int(length)

            let totalNeeded = lengthBytes + messageLength

            guard buffer.count >= totalNeeded else {
                return nil
            }

            let message = Data(buffer.prefix(totalNeeded))
            buffer = Data(buffer.dropFirst(totalNeeded))
            return message
        } catch VarintError.insufficientData {
            return nil
        } catch VarintError.overflow, VarintError.valueExceedsIntMax {
            throw UpgradeError.invalidVarint
        }
    }
}

/// Errors that can occur during connection upgrade.
public enum UpgradeError: Error, Sendable {
    case noSecurityUpgraders
    case noMuxers
    case securityNegotiationFailed(String)
    case muxerNegotiationFailed(String)
    case connectionClosed
    case messageTooLarge(size: Int, max: Int)
    case invalidVarint
}
