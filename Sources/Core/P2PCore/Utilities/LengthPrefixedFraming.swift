/// Utilities for 2-byte big-endian length-prefixed framing.
///
/// Frame format: `[2-byte BE length][payload]`
///
/// Used by Noise and TLS security protocols which share identical framing logic.
import Foundation

/// Framing error for length-prefixed messages.
public enum FramingError: Error, Sendable {
    /// Frame size exceeds the maximum allowed.
    case frameTooLarge(size: Int, max: Int)
}

/// Reads a 2-byte big-endian length-prefixed message from a buffer.
///
/// - Parameters:
///   - buffer: The data buffer to read from
///   - maxMessageSize: Maximum allowed message size
/// - Returns: Tuple of (message data, bytes consumed) or nil if incomplete
/// - Throws: `FramingError.frameTooLarge` if length exceeds maximum
public func readLengthPrefixedFrame(from buffer: Data, maxMessageSize: Int) throws -> (message: Data, consumed: Int)? {
    guard buffer.count >= 2 else { return nil }

    let length = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])

    guard length <= maxMessageSize else {
        throw FramingError.frameTooLarge(size: length, max: maxMessageSize)
    }

    guard buffer.count >= 2 + length else { return nil }

    let message = Data(buffer[buffer.startIndex + 2 ..< buffer.startIndex + 2 + length])
    return (message, 2 + length)
}

/// Encodes a message with a 2-byte big-endian length prefix.
///
/// - Parameters:
///   - message: The message data to encode
///   - maxMessageSize: Maximum allowed message size
/// - Returns: Length-prefixed message
/// - Throws: `FramingError.frameTooLarge` if message exceeds maximum
public func encodeLengthPrefixedFrame(_ message: Data, maxMessageSize: Int) throws -> Data {
    guard message.count <= maxMessageSize else {
        throw FramingError.frameTooLarge(size: message.count, max: maxMessageSize)
    }

    var result = Data(capacity: 2 + message.count)
    result.append(UInt8((message.count >> 8) & 0xFF))
    result.append(UInt8(message.count & 0xFF))
    result.append(message)
    return result
}
