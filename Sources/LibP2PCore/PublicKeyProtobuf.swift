/// libp2p PublicKey protobuf framing (Embedded-clean).
/// https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md
///
/// Embedded-clean: no Foundation, no Crypto, no `any`. This is the
/// `PublicKey` protobuf *framing* over `[UInt8]`:
///
/// ```protobuf
/// message PublicKey {
///   KeyType Type = 1;   // varint  (wire type 0)
///   bytes   Data = 2;   // raw key (wire type 2)
/// }
/// ```
///
/// The actual key construction / signature verification (CryptoKit) stays in the
/// `P2PCore` adapter via the Crypto seam; only the byte framing lives here.

/// The decoded fields of a libp2p PublicKey protobuf.
public struct PublicKeyProtobuf: Sendable, Equatable {

    /// The raw KeyType varint value (field 1).
    public let keyType: UInt64

    /// The raw key bytes (field 2).
    public let keyData: [UInt8]

    public init(keyType: UInt64, keyData: [UInt8]) {
        self.keyType = keyType
        self.keyData = keyData
    }

    /// Encodes the key type + raw key bytes into the libp2p PublicKey protobuf.
    ///
    /// - Parameters:
    ///   - keyType: The KeyType varint value (e.g. 1 for Ed25519).
    ///   - keyData: The raw public key bytes.
    /// - Returns: The protobuf-encoded bytes.
    public static func encode(keyType: UInt64, keyData: [UInt8]) -> [UInt8] {
        var encoded = [UInt8]()
        encoded.append(0x08) // field 1, wire type 0 (varint)
        encoded.append(contentsOf: Varint.encodeBytes(keyType))
        encoded.append(0x12) // field 2, wire type 2 (length-delimited)
        encoded.append(contentsOf: Varint.encodeBytes(UInt64(keyData.count)))
        encoded.append(contentsOf: keyData)
        return encoded
    }

    /// Decodes a libp2p PublicKey protobuf into its key-type and key-data fields.
    ///
    /// Uses the mixed-wire-type layout (varint field 1, length-delimited field 2)
    /// — this is why it is its own decoder and not `decodeProtobufFields`, which
    /// is wire-type-2 only.
    ///
    /// - Parameters:
    ///   - bytes: The protobuf-encoded public key.
    ///   - maxKeyDataLength: Reject key data longer than this (DoS bound).
    /// - Throws: `PublicKeyProtobufError` on malformed input.
    public static func decode(
        from bytes: [UInt8], maxKeyDataLength: Int = 4096
    ) throws(PublicKeyProtobufError) -> PublicKeyProtobuf {
        var offset = 0
        var keyType: UInt64?
        var keyData: [UInt8]?

        while offset < bytes.count {
            let fieldTag: UInt64
            let fieldBytes: Int
            do {
                (fieldTag, fieldBytes) = try Varint.decode(from: bytes, at: offset)
            } catch {
                throw .invalidProtobuf
            }
            offset += fieldBytes

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0): // KeyType varint
                let typeValue: UInt64
                let typeBytes: Int
                do {
                    (typeValue, typeBytes) = try Varint.decode(from: bytes, at: offset)
                } catch {
                    throw .invalidProtobuf
                }
                offset += typeBytes
                keyType = typeValue

            case (2, 2): // Data length-delimited
                let length: UInt64
                let lengthBytes: Int
                do {
                    (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                } catch {
                    throw .invalidProtobuf
                }
                offset += lengthBytes
                guard length <= UInt64(maxKeyDataLength) else {
                    throw .keyDataTooLarge(length)
                }
                let keyLength = Int(length)
                let keyDataEnd = offset + keyLength
                guard keyDataEnd <= bytes.count else {
                    throw .invalidProtobuf
                }
                keyData = Array(bytes[offset..<keyDataEnd])
                offset = keyDataEnd

            default:
                throw .invalidProtobuf
            }
        }

        guard let type = keyType, let data = keyData else {
            throw .invalidProtobuf
        }
        return PublicKeyProtobuf(keyType: type, keyData: data)
    }
}

/// Errors from the libp2p PublicKey protobuf framing.
public enum PublicKeyProtobufError: Error, Equatable, Sendable {
    case invalidProtobuf
    case keyDataTooLarge(UInt64)
}
