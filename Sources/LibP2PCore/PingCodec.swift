/// libp2p Ping payload codec (Embedded-clean).
/// https://github.com/libp2p/specs/blob/master/ping/ping.md
///
/// Embedded-clean: no Foundation, no NIO, no `any`, no RNG. The Ping protocol
/// exchanges a fixed 32-byte random payload that the responder echoes verbatim.
/// This core owns the payload-size constant and the length validation; the random
/// payload generation (RNG) and the echo stream loop stay in the `P2PPing`
/// adapter.

public enum PingCodec {

    /// The Ping payload size in bytes (32, per the libp2p spec).
    public static let payloadSize = 32

    /// Validates that `payload` has exactly the required size.
    ///
    /// - Parameter payload: The candidate ping payload bytes.
    /// - Throws: `PingCodecError.invalidLength` if the length is not `payloadSize`.
    public static func validate(_ payload: [UInt8]) throws(PingCodecError) {
        guard payload.count == payloadSize else {
            throw .invalidLength(payload.count)
        }
    }

    /// Whether `payload` has exactly the required size.
    ///
    /// - Parameter payload: The candidate ping payload bytes.
    /// - Returns: `true` if the length equals `payloadSize`.
    public static func isValid(_ payload: [UInt8]) -> Bool {
        payload.count == payloadSize
    }
}

/// Errors from the Ping payload codec.
public enum PingCodecError: Error, Equatable, Sendable {
    /// The payload length is not the required `PingCodec.payloadSize`.
    case invalidLength(Int)
}
