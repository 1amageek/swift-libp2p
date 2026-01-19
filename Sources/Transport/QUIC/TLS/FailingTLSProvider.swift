/// A TLS provider that always fails.
///
/// Used when TLS provider creation fails, to properly propagate
/// the error during handshake instead of crashing at creation time.
///
/// This allows the QUIC layer to handle the error gracefully rather
/// than using `fatalError` when certificate generation fails.

import Foundation
import Crypto
import QUICCrypto
import QUICCore

/// A TLS provider that fails all operations.
///
/// This is used as a fallback when the real TLS provider cannot be created
/// (e.g., due to certificate generation failure). Instead of crashing with
/// `fatalError`, this provider is returned and will fail gracefully during
/// the handshake phase, allowing proper error handling.
@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
public final class FailingTLSProvider: TLS13Provider, @unchecked Sendable {

    /// The error that occurred during provider creation.
    private let creationError: Error

    /// Creates a failing TLS provider.
    ///
    /// - Parameter error: The error that caused provider creation to fail
    public init(error: Error) {
        self.creationError = error
    }

    // MARK: - TLS13Provider Protocol

    public func startHandshake(isClient: Bool) async throws -> [TLSOutput] {
        throw TLSError.internalError("TLS provider creation failed: \(creationError)")
    }

    public func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput] {
        throw TLSError.internalError("TLS provider creation failed: \(creationError)")
    }

    public func getLocalTransportParameters() -> Data {
        Data()
    }

    public func setLocalTransportParameters(_ params: Data) throws {
        throw TLSError.internalError("TLS provider creation failed: \(creationError)")
    }

    public func getPeerTransportParameters() -> Data? {
        nil
    }

    public var isHandshakeComplete: Bool {
        false
    }

    public var isClient: Bool {
        false
    }

    public var negotiatedALPN: String? {
        nil
    }

    public func requestKeyUpdate() async throws -> [TLSOutput] {
        throw TLSError.internalError("TLS provider creation failed: \(creationError)")
    }

    public func exportKeyingMaterial(label: String, context: Data?, length: Int) throws -> Data {
        throw TLSError.internalError("TLS provider creation failed: \(creationError)")
    }

    public func configureResumption(ticket: SessionTicketData, attemptEarlyData: Bool) throws {
        throw TLSError.internalError("TLS provider creation failed: \(creationError)")
    }

    public var is0RTTAccepted: Bool {
        false
    }

    public var is0RTTAttempted: Bool {
        false
    }
}
