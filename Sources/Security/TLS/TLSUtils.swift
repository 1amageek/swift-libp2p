/// TLSUtils - Shared utilities for TLS module
import Foundation

// MARK: - TLS Constants

/// Maximum TLS message size (16KB + overhead for tag).
let tlsMaxMessageSize = 16640

/// Maximum plaintext size per TLS frame (message size - auth tag).
let tlsMaxPlaintextSize = tlsMaxMessageSize - tlsAuthTagSize

/// AES-GCM authentication tag size (16 bytes).
let tlsAuthTagSize = 16

/// AES-GCM nonce size (12 bytes).
let tlsNonceSize = 12

// MARK: - Frame Encoding/Decoding

/// Reads a length-prefixed TLS message from buffer.
///
/// Frame format: `[2-byte BE length][payload]`
///
/// - Parameter buffer: The data buffer to read from
/// - Returns: Tuple of (message data, bytes consumed) or nil if incomplete
/// - Throws: `TLSError.frameTooLarge` if length exceeds maximum
func readTLSMessage(from buffer: Data) throws -> (message: Data, consumed: Int)? {
    guard buffer.count >= 2 else { return nil }

    let length = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])

    guard length <= tlsMaxMessageSize else {
        throw TLSError.frameTooLarge(size: length, max: tlsMaxMessageSize)
    }

    guard buffer.count >= 2 + length else { return nil }

    let message = Data(buffer[buffer.startIndex + 2 ..< buffer.startIndex + 2 + length])
    return (message, 2 + length)
}

/// Encodes a TLS message with 2-byte length prefix.
///
/// - Parameter message: The message data to encode
/// - Returns: Length-prefixed message
/// - Throws: `TLSError.frameTooLarge` if message exceeds maximum
func encodeTLSMessage(_ message: Data) throws -> Data {
    guard message.count <= tlsMaxMessageSize else {
        throw TLSError.frameTooLarge(size: message.count, max: tlsMaxMessageSize)
    }

    var result = Data(capacity: 2 + message.count)
    result.append(UInt8((message.count >> 8) & 0xFF))
    result.append(UInt8(message.count & 0xFF))
    result.append(message)
    return result
}

// MARK: - ASN.1 Parsing

/// Parses ASN.1 DER length encoding.
///
/// DER length encoding:
/// - Short form (0-127): Single byte with length value
/// - Long form (128+): First byte = 0x80 | numBytes, followed by length bytes
///
/// - Parameters:
///   - bytes: The byte array containing ASN.1 data
///   - offset: Starting position to parse length
/// - Returns: Tuple of (length value, size of length field) or nil if invalid
func parseASN1Length(from bytes: [UInt8], at offset: Int) -> (length: Int, size: Int)? {
    guard offset < bytes.count else { return nil }

    let firstByte = bytes[offset]
    if firstByte < 128 {
        // Short form: single byte length
        return (Int(firstByte), 1)
    }

    // Long form: first byte indicates number of length bytes
    let numBytes = Int(firstByte & 0x7F)
    guard numBytes > 0, offset + numBytes < bytes.count else { return nil }

    var length = 0
    for i in 0..<numBytes {
        length = (length << 8) | Int(bytes[offset + 1 + i])
    }
    return (length, numBytes + 1)
}

/// Parses ASN.1 DER length encoding from Data.
///
/// - Parameters:
///   - data: The data containing ASN.1 structure
///   - offset: Starting position to parse length
/// - Returns: Tuple of (length value, size of length field) or nil if invalid
func parseASN1Length(from data: Data, at offset: Int) -> (length: Int, size: Int)? {
    guard offset < data.count else { return nil }

    let firstByte = data[data.startIndex + offset]
    if firstByte < 128 {
        return (Int(firstByte), 1)
    }

    let numBytes = Int(firstByte & 0x7F)
    guard numBytes > 0, offset + numBytes < data.count else { return nil }

    var length = 0
    for i in 0..<numBytes {
        length = (length << 8) | Int(data[data.startIndex + offset + 1 + i])
    }
    return (length, numBytes + 1)
}
