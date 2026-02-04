/// Utilities for 2-byte big-endian length-prefixed framing.
///
/// Frame format: `[2-byte BE length][payload]`
///
/// Used by Noise and TLS security protocols which share identical framing logic.
import Foundation
import NIOCore

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

// MARK: - ByteBuffer Optimizations (Zero-Copy)

/// Reads a 2-byte big-endian length-prefixed message from a ByteBuffer (zero-copy).
///
/// - Parameters:
///   - buffer: The ByteBuffer to read from (will be mutated to advance reader index)
///   - maxMessageSize: Maximum allowed message size
/// - Returns: The message as ByteBuffer slice, or nil if incomplete
/// - Throws: `FramingError.frameTooLarge` if length exceeds maximum
public func readLengthPrefixedFrame(from buffer: inout ByteBuffer, maxMessageSize: Int) throws -> ByteBuffer? {
    guard buffer.readableBytes >= 2 else { return nil }

    // Peek at length without consuming
    guard let lengthBytes = buffer.getBytes(at: buffer.readerIndex, length: 2) else {
        return nil
    }

    let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])

    guard length <= maxMessageSize else {
        throw FramingError.frameTooLarge(size: length, max: maxMessageSize)
    }

    guard buffer.readableBytes >= 2 + length else { return nil }

    // Skip length prefix
    buffer.moveReaderIndex(forwardBy: 2)

    // Return zero-copy slice
    return buffer.readSlice(length: length)
}

/// Encodes a message with a 2-byte big-endian length prefix (zero-copy for ByteBuffer).
///
/// - Parameters:
///   - message: The message ByteBuffer to encode
///   - maxMessageSize: Maximum allowed message size
///   - buffer: Output ByteBuffer (will be mutated)
/// - Throws: `FramingError.frameTooLarge` if message exceeds maximum
public func encodeLengthPrefixedFrame(_ message: ByteBuffer, maxMessageSize: Int, into buffer: inout ByteBuffer) throws {
    guard message.readableBytes <= maxMessageSize else {
        throw FramingError.frameTooLarge(size: message.readableBytes, max: maxMessageSize)
    }

    let length = message.readableBytes
    buffer.writeInteger(UInt16(length))
    var messageCopy = message
    buffer.writeBuffer(&messageCopy)
}
