/// libp2p Identify message codec (Embedded-clean).
/// https://github.com/libp2p/specs/blob/master/identify/README.md
///
/// Embedded-clean: no Foundation, no NIO, no `any`. This is the Identify protobuf
/// wire codec over `[UInt8]`, expressed as raw value fields:
///
/// ```protobuf
/// message Identify {
///   optional bytes  publicKey       = 1;
///   repeated bytes  listenAddrs     = 2;   // each a binary multiaddr
///   repeated string protocols       = 3;
///   optional bytes  observedAddr    = 4;   // binary multiaddr
///   optional string protocolVersion = 5;
///   optional string agentVersion    = 6;
///   optional bytes  signedPeerRecord = 8;  // field 7 is skipped
/// }
/// ```
///
/// The domain types — `PublicKey` (from `publicKey`), `Multiaddr`
/// (from `listenAddrs` / `observedAddr` bytes via `MultiaddrCodec`), and the
/// `Envelope` signed peer record — are reconstructed in the `P2PIdentify`
/// adapter; only the byte framing lives here. The multiaddr bytes are produced /
/// consumed by the adapter using the cored `MultiaddrCodec`, and the publicKey
/// bytes use the cored `PublicKeyProtobuf`.

/// The decoded raw fields of an Identify message.
///
/// Byte fields stay raw (`[UInt8]`); the adapter parses them into `PublicKey`,
/// `Multiaddr`, and `Envelope`. String fields are strictly UTF-8 decoded.
public struct IdentifyFields: Sendable, Equatable {

    /// The libp2p public key, protobuf-encoded (field 1).
    public var publicKey: [UInt8]?

    /// Listen addresses, each a binary multiaddr (field 2, repeated).
    public var listenAddrs: [[UInt8]]

    /// Supported protocol IDs (field 3, repeated).
    public var protocols: [String]

    /// The observed address, a binary multiaddr (field 4).
    public var observedAddr: [UInt8]?

    /// The protocol version string (field 5).
    public var protocolVersion: String?

    /// The agent version string (field 6).
    public var agentVersion: String?

    /// The signed peer record envelope, marshalled (field 8).
    public var signedPeerRecord: [UInt8]?

    public init(
        publicKey: [UInt8]? = nil,
        listenAddrs: [[UInt8]] = [],
        protocols: [String] = [],
        observedAddr: [UInt8]? = nil,
        protocolVersion: String? = nil,
        agentVersion: String? = nil,
        signedPeerRecord: [UInt8]? = nil
    ) {
        self.publicKey = publicKey
        self.listenAddrs = listenAddrs
        self.protocols = protocols
        self.observedAddr = observedAddr
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.signedPeerRecord = signedPeerRecord
    }

    // MARK: - Field tags (field number << 3 | wire type 2)

    @usableFromInline static let tagPublicKey: UInt8 = 0x0A       // field 1
    @usableFromInline static let tagListenAddrs: UInt8 = 0x12     // field 2
    @usableFromInline static let tagProtocols: UInt8 = 0x1A       // field 3
    @usableFromInline static let tagObservedAddr: UInt8 = 0x22    // field 4
    @usableFromInline static let tagProtocolVersion: UInt8 = 0x2A // field 5
    @usableFromInline static let tagAgentVersion: UInt8 = 0x32    // field 6
    @usableFromInline static let tagSignedPeerRecord: UInt8 = 0x42 // field 8

    // MARK: - Encoding

    /// Encodes the fields to Identify protobuf wire format.
    ///
    /// Field order matches the historical encoder (1, 2, 3, 4, 5, 6, 8). Optional
    /// fields that are `nil` are omitted; repeated fields emit one entry each.
    public func encode() -> [UInt8] {
        var result = [UInt8]()

        if let publicKey {
            appendField(&result, tag: IdentifyFields.tagPublicKey, bytes: publicKey)
        }
        for addr in listenAddrs {
            appendField(&result, tag: IdentifyFields.tagListenAddrs, bytes: addr)
        }
        for proto in protocols {
            appendField(&result, tag: IdentifyFields.tagProtocols, bytes: [UInt8](proto.utf8))
        }
        if let observedAddr {
            appendField(&result, tag: IdentifyFields.tagObservedAddr, bytes: observedAddr)
        }
        if let protocolVersion {
            appendField(&result, tag: IdentifyFields.tagProtocolVersion, bytes: [UInt8](protocolVersion.utf8))
        }
        if let agentVersion {
            appendField(&result, tag: IdentifyFields.tagAgentVersion, bytes: [UInt8](agentVersion.utf8))
        }
        if let signedPeerRecord {
            appendField(&result, tag: IdentifyFields.tagSignedPeerRecord, bytes: signedPeerRecord)
        }

        return result
    }

    @inline(__always)
    private func appendField(_ out: inout [UInt8], tag: UInt8, bytes: [UInt8]) {
        out.append(tag)
        out.append(contentsOf: Varint.encodeBytes(UInt64(bytes.count)))
        out.append(contentsOf: bytes)
    }

    // MARK: - Decoding

    /// Decodes an Identify message from protobuf wire format.
    ///
    /// Behaviour preserved from the historical decoder:
    /// - Non-length-delimited wire types (0/1/5) are skipped, not errored.
    /// - Unknown length-delimited field numbers are skipped.
    /// - A `protocols` entry whose bytes are not valid UTF-8 is silently dropped.
    /// - `protocolVersion` / `agentVersion` keep their value only when valid
    ///   UTF-8; invalid UTF-8 leaves them `nil` (the field is still consumed).
    /// - Byte fields (publicKey/listenAddrs/observedAddr/signedPeerRecord) stay
    ///   raw here; the adapter validates them when reconstructing domain types.
    ///
    /// - Parameters:
    ///   - bytes: The protobuf-encoded Identify message.
    ///   - maxFieldSize: Reject any single field whose declared length exceeds
    ///     this bound (a 0.2.0 field-limit security bound).
    /// - Throws: `IdentifyCodecError` on truncated / malformed framing.
    public static func decode(
        from bytes: [UInt8],
        maxFieldSize: Int = 1_048_576
    ) throws(IdentifyCodecError) -> IdentifyFields {
        var fields = IdentifyFields()
        var offset = 0

        while offset < bytes.count {
            let tag: UInt64
            let tagBytes: Int
            do {
                (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
            } catch {
                throw .truncated
            }
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == 2 else {
                offset = try IdentifyFields.skipNonLengthDelimited(
                    wireType: wireType, bytes: bytes, offset: offset
                )
                continue
            }

            let lengthValue: UInt64
            let lengthBytes: Int
            do {
                (lengthValue, lengthBytes) = try Varint.decode(from: bytes, at: offset)
            } catch {
                throw .truncated
            }
            offset += lengthBytes

            guard lengthValue <= UInt64(maxFieldSize) else {
                throw .fieldTooLarge(size: lengthValue, max: maxFieldSize)
            }
            let length = Int(lengthValue)
            let fieldEnd = offset + length
            guard fieldEnd <= bytes.count else {
                throw .truncated
            }

            let value = Array(bytes[offset..<fieldEnd])

            switch fieldNumber {
            case 1: fields.publicKey = value
            case 2: fields.listenAddrs.append(value)
            case 3:
                if let proto = decodeUTF8Strict(value) {
                    fields.protocols.append(proto)
                }
            case 4: fields.observedAddr = value
            case 5: fields.protocolVersion = decodeUTF8Strict(value)
            case 6: fields.agentVersion = decodeUTF8Strict(value)
            case 8: fields.signedPeerRecord = value
            default: break
            }

            offset = fieldEnd
        }

        return fields
    }

    /// Advances past a non-length-delimited field (wire types 0/1/5).
    private static func skipNonLengthDelimited(
        wireType: UInt64, bytes: [UInt8], offset: Int
    ) throws(IdentifyCodecError) -> Int {
        var newOffset = offset
        switch wireType {
        case 0:
            let bytesRead: Int
            do {
                (_, bytesRead) = try Varint.decode(from: bytes, at: newOffset)
            } catch {
                throw .truncated
            }
            newOffset += bytesRead
        case 1:
            newOffset += 8
        case 5:
            newOffset += 4
        default:
            throw .unexpectedWireType(wireType)
        }
        guard newOffset <= bytes.count else {
            throw .truncated
        }
        return newOffset
    }
}

/// Errors from the Identify message codec.
public enum IdentifyCodecError: Error, Equatable, Sendable {
    /// A field extends beyond the available bytes, or a varint is incomplete.
    case truncated
    /// A field's declared length exceeds the allowed maximum.
    case fieldTooLarge(size: UInt64, max: Int)
    /// A non-length-delimited field used an unsupported wire type.
    case unexpectedWireType(UInt64)
}
