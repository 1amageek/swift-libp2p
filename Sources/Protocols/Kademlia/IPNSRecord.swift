/// IPNSRecord - An IPNS name record stored in the DHT under /ipns/<peerID> keys.
///
/// IPNS (InterPlanetary Name System) provides mutable pointers in the IPFS ecosystem.
/// Each record maps a PeerID-derived name to a content path (CID or IPFS path),
/// with sequence numbers for ordering and expiry times for freshness.
///
/// Wire format uses a simple protobuf-compatible encoding:
///   Field 1 (bytes):  value
///   Field 2 (varint): validityType
///   Field 3 (bytes):  validity (RFC 3339 date string)
///   Field 4 (varint): sequence
///   Field 5 (bytes):  signature
///   Field 6 (bytes):  publicKey (optional)

import Foundation
import P2PCore
import Synchronization

/// Errors specific to IPNS record operations.
public enum IPNSRecordError: Error, Sendable, Equatable {
    /// The binary data could not be decoded as an IPNS record.
    case invalidFormat
    /// A required field is missing from the record.
    case missingField(String)
    /// The record signature is invalid.
    case invalidSignature
    /// The record has expired (past its EOL validity).
    case expired
    /// The PeerID in the key does not match the record signer.
    case keyMismatch
    /// The signing operation failed.
    case signingFailed
    /// The public key could not be extracted or verified.
    case invalidPublicKey
}

/// An IPNS name record stored in the DHT under /ipns/<peerID> keys.
public struct IPNSRecord: Sendable, Equatable {
    /// The value (CID or IPFS path) this name points to.
    public let value: [UInt8]

    /// Sequence number for ordering (higher = newer).
    public let sequence: UInt64

    /// When this record expires (EOL = End of Life).
    public let validity: Date

    /// Validity type (always EOL = 0 for now).
    public let validityType: ValidityType

    /// Signature over the record by the owner's key.
    public let signature: [UInt8]

    /// The public key of the signer (may be embedded or derivable from PeerID).
    public let publicKey: [UInt8]?

    public enum ValidityType: UInt8, Sendable {
        case eol = 0  // End of Life (expiry time)
    }

    /// Creates an IPNSRecord from its constituent parts.
    public init(
        value: [UInt8],
        sequence: UInt64,
        validity: Date,
        validityType: ValidityType,
        signature: [UInt8],
        publicKey: [UInt8]?
    ) {
        self.value = value
        self.sequence = sequence
        self.validity = validity
        self.validityType = validityType
        self.signature = signature
        self.publicKey = publicKey
    }

    // MARK: - Signing Data

    /// Builds the data that is signed: value + validityType + validity (RFC 3339 string).
    /// This matches the go-ipfs signing scheme for IPNS records.
    static func dataForSigning(value: [UInt8], validityType: ValidityType, validity: Date) -> Data {
        let validityBytes = Data(Self.formatDate(validity).utf8)
        var signable = Data(capacity: value.count + 1 + validityBytes.count)
        signable.append(contentsOf: value)
        signable.append(validityType.rawValue)
        signable.append(validityBytes)
        return signable
    }

    // MARK: - Date Formatting

    /// Formats a Date to RFC 3339 format matching go-ipfs expectations.
    static func formatDate(_ date: Date) -> String {
        DateFormatting.fractional.withLock { formatter in
            formatter.string(from: date)
        }
    }

    /// Parses an RFC 3339 date string.
    static func parseDate(_ string: String) throws -> Date {
        if let date = DateFormatting.fractional.withLock({ formatter in
            formatter.date(from: string)
        }) {
            return date
        }
        if let date = DateFormatting.plain.withLock({ formatter in
            formatter.date(from: string)
        }) {
            return date
        }
        throw IPNSRecordError.invalidFormat
    }

    // MARK: - Encode

    /// Encode to protobuf-compatible binary format.
    ///
    /// Field layout:
    ///   1 (LEN): value
    ///   2 (varint): validityType
    ///   3 (LEN): validity (RFC 3339 date as UTF-8 bytes)
    ///   4 (varint): sequence
    ///   5 (LEN): signature
    ///   6 (LEN): publicKey (optional)
    public func encode() -> [UInt8] {
        let validityBytes = Data(Self.formatDate(validity).utf8)
        let estimatedSize = 24 + value.count + validityBytes.count + signature.count + (publicKey?.count ?? 0)
        var result = Data(capacity: estimatedSize)

        // Field 1: value (wire type 2 = length-delimited)
        appendTag(fieldNumber: 1, wireType: 2, to: &result)
        Varint.encode(UInt64(value.count), into: &result)
        result.append(contentsOf: value)

        // Field 2: validityType (wire type 0 = varint)
        appendTag(fieldNumber: 2, wireType: 0, to: &result)
        Varint.encode(UInt64(validityType.rawValue), into: &result)

        // Field 3: validity (wire type 2 = length-delimited, RFC 3339 string)
        appendTag(fieldNumber: 3, wireType: 2, to: &result)
        Varint.encode(UInt64(validityBytes.count), into: &result)
        result.append(contentsOf: validityBytes)

        // Field 4: sequence (wire type 0 = varint)
        appendTag(fieldNumber: 4, wireType: 0, to: &result)
        Varint.encode(sequence, into: &result)

        // Field 5: signature (wire type 2 = length-delimited)
        appendTag(fieldNumber: 5, wireType: 2, to: &result)
        Varint.encode(UInt64(signature.count), into: &result)
        result.append(contentsOf: signature)

        // Field 6: publicKey (wire type 2 = length-delimited, optional)
        if let pk = publicKey {
            appendTag(fieldNumber: 6, wireType: 2, to: &result)
            Varint.encode(UInt64(pk.count), into: &result)
            result.append(contentsOf: pk)
        }

        return Array(result)
    }

    // MARK: - Decode

    /// Decode from protobuf-compatible binary format.
    public static func decode(from data: [UInt8]) throws -> IPNSRecord {
        let inputData = Data(data)
        var offset = 0

        var value: [UInt8]?
        var validityType: ValidityType?
        var validityString: String?
        var sequence: UInt64?
        var signature: [UInt8]?
        var publicKey: [UInt8]?

        while offset < inputData.count {
            let (fieldTag, tagBytes) = try Varint.decode(from: inputData, at: offset)
            offset += tagBytes

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            switch (fieldNumber, wireType) {
            case (1, 2): // value (length-delimited)
                let (length, lengthBytes) = try Varint.decode(from: inputData, at: offset)
                offset += lengthBytes
                let len = try Varint.toInt(length)
                guard offset + len <= inputData.count else {
                    throw IPNSRecordError.invalidFormat
                }
                value = Array(inputData[inputData.startIndex + offset ..< inputData.startIndex + offset + len])
                offset += len

            case (2, 0): // validityType (varint)
                let (typeValue, typeBytes) = try Varint.decode(from: inputData, at: offset)
                offset += typeBytes
                guard let vt = ValidityType(rawValue: UInt8(typeValue)) else {
                    throw IPNSRecordError.invalidFormat
                }
                validityType = vt

            case (3, 2): // validity (length-delimited, RFC 3339 string)
                let (length, lengthBytes) = try Varint.decode(from: inputData, at: offset)
                offset += lengthBytes
                let len = try Varint.toInt(length)
                guard offset + len <= inputData.count else {
                    throw IPNSRecordError.invalidFormat
                }
                let bytes = inputData[inputData.startIndex + offset ..< inputData.startIndex + offset + len]
                guard let str = String(data: Data(bytes), encoding: .utf8) else {
                    throw IPNSRecordError.invalidFormat
                }
                validityString = str
                offset += len

            case (4, 0): // sequence (varint)
                let (seqValue, seqBytes) = try Varint.decode(from: inputData, at: offset)
                offset += seqBytes
                sequence = seqValue

            case (5, 2): // signature (length-delimited)
                let (length, lengthBytes) = try Varint.decode(from: inputData, at: offset)
                offset += lengthBytes
                let len = try Varint.toInt(length)
                guard offset + len <= inputData.count else {
                    throw IPNSRecordError.invalidFormat
                }
                signature = Array(inputData[inputData.startIndex + offset ..< inputData.startIndex + offset + len])
                offset += len

            case (6, 2): // publicKey (length-delimited, optional)
                let (length, lengthBytes) = try Varint.decode(from: inputData, at: offset)
                offset += lengthBytes
                let len = try Varint.toInt(length)
                guard offset + len <= inputData.count else {
                    throw IPNSRecordError.invalidFormat
                }
                publicKey = Array(inputData[inputData.startIndex + offset ..< inputData.startIndex + offset + len])
                offset += len

            default:
                // Skip unknown fields for forward compatibility
                switch wireType {
                case 0: // varint: consume bytes
                    let (_, skipBytes) = try Varint.decode(from: inputData, at: offset)
                    offset += skipBytes
                case 1: // fixed 64-bit: skip 8 bytes
                    guard offset + 8 <= inputData.count else {
                        throw IPNSRecordError.invalidFormat
                    }
                    offset += 8
                case 2: // length-delimited: skip
                    let (length, lengthBytes) = try Varint.decode(from: inputData, at: offset)
                    offset += lengthBytes
                    let len = try Varint.toInt(length)
                    guard offset + len <= inputData.count else {
                        throw IPNSRecordError.invalidFormat
                    }
                    offset += len
                case 5: // fixed 32-bit: skip 4 bytes
                    guard offset + 4 <= inputData.count else {
                        throw IPNSRecordError.invalidFormat
                    }
                    offset += 4
                default:
                    throw IPNSRecordError.invalidFormat
                }
            }
        }

        guard let val = value else {
            throw IPNSRecordError.missingField("value")
        }
        guard let vt = validityType else {
            throw IPNSRecordError.missingField("validityType")
        }
        guard let vs = validityString else {
            throw IPNSRecordError.missingField("validity")
        }
        guard let seq = sequence else {
            throw IPNSRecordError.missingField("sequence")
        }
        guard let sig = signature else {
            throw IPNSRecordError.missingField("signature")
        }

        let validityDate = try parseDate(vs)

        return IPNSRecord(
            value: val,
            sequence: seq,
            validity: validityDate,
            validityType: vt,
            signature: sig,
            publicKey: publicKey
        )
    }

    // MARK: - Create (Signed)

    /// Create a signed IPNS record.
    ///
    /// Signs the record using the provided key pair. The signature covers:
    ///   value + validityType + validity (RFC 3339 string)
    ///
    /// - Parameters:
    ///   - value: The content path (CID or IPFS path) as bytes.
    ///   - sequence: Sequence number for ordering.
    ///   - validity: When this record expires.
    ///   - keyPair: The key pair used to sign the record.
    /// - Returns: A signed IPNSRecord.
    /// - Throws: `IPNSRecordError.signingFailed` if signing fails.
    public static func create(
        value: [UInt8],
        sequence: UInt64,
        validity: Date,
        keyPair: KeyPair
    ) throws -> IPNSRecord {
        let validityType = ValidityType.eol
        let signable = dataForSigning(value: value, validityType: validityType, validity: validity)

        let signatureData: Data
        do {
            signatureData = try keyPair.sign(signable)
        } catch {
            throw IPNSRecordError.signingFailed
        }

        return IPNSRecord(
            value: value,
            sequence: sequence,
            validity: validity,
            validityType: validityType,
            signature: Array(signatureData),
            publicKey: Array(keyPair.publicKey.protobufEncoded)
        )
    }

    // MARK: - Helpers

    /// Appends a protobuf field tag.
    private func appendTag(fieldNumber: UInt64, wireType: UInt64, to data: inout Data) {
        Varint.encode((fieldNumber << 3) | wireType, into: &data)
    }
}

private enum DateFormatting {
    static let fractional = Mutex(makeFractionalFormatter())
    static let plain = Mutex(makePlainFormatter())

    private static func makeFractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    private static func makePlainFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }
}
