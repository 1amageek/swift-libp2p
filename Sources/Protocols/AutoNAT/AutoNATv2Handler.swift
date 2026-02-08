/// AutoNATv2Handler - Stream handler for AutoNAT v2 protocol.
///
/// Handles incoming and outgoing AutoNAT v2 protocol streams,
/// coordinating between the service and the multiplexed streams.

import Foundation
import P2PCore
import P2PMux
import P2PProtocols

/// Handler for AutoNAT v2 protocol streams.
///
/// This handler coordinates the protocol exchange between client and server,
/// delegating nonce management and state tracking to the `AutoNATv2Service`.
public final class AutoNATv2Handler: Sendable {

    /// The AutoNAT v2 service managing state and nonce verification.
    private let service: AutoNATv2Service

    /// Creates a new handler.
    ///
    /// - Parameter service: The AutoNAT v2 service to use.
    public init(service: AutoNATv2Service) {
        self.service = service
    }

    // MARK: - Server Side

    /// Handles an incoming AutoNAT v2 stream (server-side).
    ///
    /// Reads the DialRequest, attempts to dial back the client's address
    /// to send the nonce, and sends the DialResponse.
    ///
    /// - Parameters:
    ///   - stream: The incoming multiplexed stream.
    ///   - dialer: A closure that dials an address and sends the nonce.
    ///             The dialer should open a connection to the address and
    ///             send the nonce value for verification.
    public func handleStream(
        _ stream: MuxedStream,
        dialer: @escaping @Sendable (Multiaddr, UInt64) async throws -> Void
    ) async throws {
        // Read the dial request
        let requestBuffer = try await stream.readLengthPrefixedMessage(
            maxSize: UInt64(AutoNATProtocol.maxMessageSize)
        )
        let message = try AutoNATv2Codec.decode(Data(buffer: requestBuffer))

        guard case .dialRequest(let request) = message else {
            // Send bad request response
            let errorResponse = AutoNATv2Message.dialResponse(
                .init(status: .badRequest)
            )
            let data = AutoNATv2Codec.encode(errorResponse)
            try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: data))
            throw AutoNATv2Error.protocolViolation("Expected DialRequest")
        }

        // Attempt dial-back with the nonce
        do {
            try await dialer(request.address, request.nonce)

            // Dial-back succeeded, send OK response
            let response = AutoNATv2Message.dialResponse(
                .init(status: .ok, address: request.address)
            )
            let data = AutoNATv2Codec.encode(response)
            try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: data))

        } catch {
            // Dial-back failed, send error response
            let response = AutoNATv2Message.dialResponse(
                .init(status: .dialError, address: request.address)
            )
            let data = AutoNATv2Codec.encode(response)
            try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: data))
        }
    }

    // MARK: - Client Side

    /// Initiates a reachability check for the given address (client-side).
    ///
    /// Sends a DialRequest with a nonce, waits for the server to dial back
    /// and verify the nonce, then reads the DialResponse.
    ///
    /// - Parameters:
    ///   - address: The address to check reachability for.
    ///   - stream: The stream to the server.
    /// - Returns: The reachability result.
    public func initiateCheck(
        address: Multiaddr,
        via stream: MuxedStream
    ) async throws -> AutoNATv2Service.Reachability {
        // Generate nonce and register pending check
        let nonce = service.generateNonce()
        service.registerPendingCheck(address: address, nonce: nonce)

        do {
            // Send dial request
            let request = AutoNATv2Message.dialRequest(
                .init(address: address, nonce: nonce)
            )
            let requestData = AutoNATv2Codec.encode(request)
            try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: requestData))

            // Read response
            let responseBuffer = try await stream.readLengthPrefixedMessage(
                maxSize: UInt64(AutoNATProtocol.maxMessageSize)
            )
            let response = try AutoNATv2Codec.decode(Data(buffer: responseBuffer))

            // Clean up pending check
            service.removePendingCheck(nonce: nonce)

            guard case .dialResponse(let dialResp) = response else {
                throw AutoNATv2Error.protocolViolation("Expected DialResponse")
            }

            switch dialResp.status {
            case .ok:
                return .publiclyReachable
            case .dialError, .dialBackError:
                return .privateOnly
            case .badRequest, .internalError:
                throw AutoNATv2Error.dialBackFailed("Server returned status: \(dialResp.status)")
            }

        } catch {
            service.removePendingCheck(nonce: nonce)
            throw error
        }
    }
}
