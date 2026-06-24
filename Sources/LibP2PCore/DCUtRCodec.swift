/// DCUtR (Direct Connection Upgrade through Relay) message codec (Embedded-clean).
/// https://github.com/libp2p/specs/blob/master/relay/DCUtR.md
///
/// Embedded-clean: no Foundation, no NIO, no `any`. This is the DCUtR HolePunch
/// protobuf wire codec over `[UInt8]`, expressed as raw value fields:
///
/// ```protobuf
/// message HolePunch {
///   Type           type     = 1;   // varint (CONNECT = 100, SYNC = 300)
///   repeated bytes ObsAddrs = 2;   // length-delimited (binary multiaddrs)
/// }
/// ```
///
/// The domain `Multiaddr` values (from `ObsAddrs` bytes) are reconstructed in
/// the `P2PDCUtR` adapter; only the byte framing lives here. Faithful
/// transcription of the historical hand-rolled protobuf path, including the
/// 0.2.0 max-observed-addresses DoS bound and the required-`type` invariant.

/// The decoded raw fields of a DCUtR HolePunch message.
///
/// `typeRawValue` is `nil` when the required `type` field was absent (the adapter
/// rejects this rather than defaulting a type, so a peer cannot steer behavior).
public struct DCUtRFields: Sendable, Equatable {
    public var typeRawValue: UInt64?
    public var observedAddresses: [[UInt8]]

    public init(typeRawValue: UInt64? = nil, observedAddresses: [[UInt8]] = []) {
        self.typeRawValue = typeRawValue
        self.observedAddresses = observedAddresses
    }

    // MARK: - Field tags

    @usableFromInline static let tagType: UInt8 = 0x08      // field 1, varint
    @usableFromInline static let tagObsAddrs: UInt8 = 0x12  // field 2, ld

    // MARK: - Encoding

    /// Encodes the fields to DCUtR protobuf wire format.
    ///
    /// `typeRawValue` is required on the wire; when nil it is encoded as 0 to keep
    /// the field present (the adapter always supplies a valid type when encoding).
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.append(DCUtRFields.tagType)
        out.append(contentsOf: Varint.encodeBytes(typeRawValue ?? 0))
        for addr in observedAddresses {
            out.append(DCUtRFields.tagObsAddrs)
            out.append(contentsOf: Varint.encodeBytes(UInt64(addr.count)))
            out.append(contentsOf: addr)
        }
        return out
    }

    // MARK: - Decoding

    /// Decodes a DCUtR message from protobuf wire format.
    ///
    /// - Parameters:
    ///   - bytes: The protobuf-encoded HolePunch message.
    ///   - maxObservedAddresses: Reject any message carrying more than this many
    ///     observed addresses (a 0.2.0 decode-amplification DoS bound).
    /// - Throws: `DCUtRCodecError` on truncated framing or when the
    ///   observed-address cap is exceeded.
    public static func decode(
        from bytes: [UInt8],
        maxObservedAddresses: Int
    ) throws(DCUtRCodecError) -> DCUtRFields {
        var typeRawValue: UInt64?
        var observedAddresses: [[UInt8]] = []

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

            switch (fieldNumber, wireType) {
            case (1, 0):
                let value: UInt64
                let valueBytes: Int
                do {
                    (value, valueBytes) = try Varint.decode(from: bytes, at: offset)
                } catch {
                    throw .truncated
                }
                offset += valueBytes
                typeRawValue = value

            case (2, 2):
                let lengthValue: UInt64
                let lengthBytes: Int
                do {
                    (lengthValue, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                } catch {
                    throw .truncated
                }
                offset += lengthBytes
                let length: Int
                do {
                    length = try Varint.toInt(lengthValue)
                } catch {
                    throw .truncated
                }
                let fieldEnd = offset + length
                guard fieldEnd <= bytes.count, fieldEnd >= offset else {
                    throw .truncated
                }
                // Bound the number of addresses to prevent decode amplification.
                guard observedAddresses.count < maxObservedAddresses else {
                    throw .tooManyObservedAddresses(max: maxObservedAddresses)
                }
                observedAddresses.append(Array(bytes[offset..<fieldEnd]))
                offset = fieldEnd

            default:
                offset = try DCUtRFields.skip(bytes, at: offset, wireType: wireType, limit: bytes.count)
            }
        }

        return DCUtRFields(typeRawValue: typeRawValue, observedAddresses: observedAddresses)
    }

    private static func skip(
        _ bytes: [UInt8], at offset: Int, wireType: UInt64, limit: Int
    ) throws(DCUtRCodecError) -> Int {
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
        case 2:
            let lengthValue: UInt64
            let lengthBytes: Int
            do {
                (lengthValue, lengthBytes) = try Varint.decode(from: bytes, at: newOffset)
            } catch {
                throw .truncated
            }
            let length: Int
            do {
                length = try Varint.toInt(lengthValue)
            } catch {
                throw .truncated
            }
            // Validate the declared length fits before advancing past it.
            guard length <= limit - newOffset else {
                throw .truncated
            }
            newOffset += lengthBytes + length
        case 5:
            newOffset += 4
        default:
            throw .unknownWireType(wireType)
        }
        guard newOffset <= limit else {
            throw .truncated
        }
        return newOffset
    }
}

/// Errors from the DCUtR message codec.
public enum DCUtRCodecError: Error, Equatable, Sendable {
    /// A field extends beyond the available bytes, or a varint is incomplete.
    case truncated
    /// A non-length-delimited field used an unsupported wire type.
    case unknownWireType(UInt64)
    /// The message carried more observed addresses than the configured cap.
    case tooManyObservedAddresses(max: Int)
}
