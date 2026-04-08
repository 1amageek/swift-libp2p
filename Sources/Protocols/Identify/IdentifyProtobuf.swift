/// IdentifyProtobuf - Wire format encoding/decoding for Identify protocol
import Foundation
import NIOCore
import P2PCore

/// Protobuf encoding/decoding for Identify messages.
///
/// Field numbers (must match libp2p spec):
/// - 1: publicKey (bytes)
/// - 2: listenAddrs (repeated bytes)
/// - 3: protocols (repeated string)
/// - 4: observedAddr (bytes)
/// - 5: protocolVersion (string)
/// - 6: agentVersion (string)
/// - 8: signedPeerRecord (bytes) - note: field 7 is skipped
enum IdentifyProtobuf {

    // MARK: - Wire Type Constants

    private static let wireTypeLengthDelimited: UInt64 = 2

    // MARK: - Field Tags (field number << 3 | wire type)

    private static let tagPublicKey: UInt8 = 0x0A       // field 1, wire type 2
    private static let tagListenAddrs: UInt8 = 0x12    // field 2, wire type 2
    private static let tagProtocols: UInt8 = 0x1A      // field 3, wire type 2
    private static let tagObservedAddr: UInt8 = 0x22   // field 4, wire type 2
    private static let tagProtocolVersion: UInt8 = 0x2A // field 5, wire type 2
    private static let tagAgentVersion: UInt8 = 0x32   // field 6, wire type 2
    private static let tagSignedPeerRecord: UInt8 = 0x42 // field 8, wire type 2

    // MARK: - Encoding

    /// Encodes IdentifyInfo to protobuf wire format.
    static func encode(_ info: IdentifyInfo) throws -> Data {
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        try encode(info, into: &buffer)
        return Data(buffer: buffer)
    }

    static func encode(_ info: IdentifyInfo, into buffer: inout ByteBuffer) throws {
        let publicKeyBytes = info.publicKey?.protobufEncoded
        let protocolBytes = info.protocols.map { Data($0.utf8) }
        let protocolVersionBytes = info.protocolVersion.map { Data($0.utf8) }
        let agentVersionBytes = info.agentVersion.map { Data($0.utf8) }
        let signedPeerRecordBytes = try info.signedPeerRecord?.marshal()

        buffer.reserveCapacity(
            buffer.writerIndex + estimatedSize(
                of: info,
                signedPeerRecordByteCount: signedPeerRecordBytes?.count
            )
        )

        // Field 1: publicKey (optional bytes)
        if let bytes = publicKeyBytes {
            buffer.writeInteger(tagPublicKey)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }

        // Field 2: listenAddrs (repeated bytes)
        for addr in info.listenAddresses {
            let bytes = addr.bytes
            buffer.writeInteger(tagListenAddrs)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }

        // Field 3: protocols (repeated string)
        for bytes in protocolBytes {
            buffer.writeInteger(tagProtocols)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }

        // Field 4: observedAddr (optional bytes)
        if let observed = info.observedAddress {
            let bytes = observed.bytes
            buffer.writeInteger(tagObservedAddr)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }

        // Field 5: protocolVersion (optional string)
        if let bytes = protocolVersionBytes {
            buffer.writeInteger(tagProtocolVersion)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }

        // Field 6: agentVersion (optional string)
        if let bytes = agentVersionBytes {
            buffer.writeInteger(tagAgentVersion)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }

        // Field 8: signedPeerRecord (optional bytes)
        if let bytes = signedPeerRecordBytes {
            buffer.writeInteger(tagSignedPeerRecord)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }
    }

    private static func estimatedSize(
        of info: IdentifyInfo,
        signedPeerRecordByteCount: Int? = nil
    ) -> Int {
        let publicKeyBytes = info.publicKey?.protobufEncoded
        let protocolVersionBytes = info.protocolVersion.map { Data($0.utf8) }
        let agentVersionBytes = info.agentVersion.map { Data($0.utf8) }

        return (publicKeyBytes.map { 2 + $0.count } ?? 0)
            + info.listenAddresses.reduce(0) { $0 + 2 + $1.bytes.count }
            + info.protocols.reduce(0) { $0 + 2 + $1.utf8.count }
            + (info.observedAddress.map { 2 + $0.bytes.count } ?? 0)
            + (protocolVersionBytes.map { 2 + $0.count } ?? 0)
            + (agentVersionBytes.map { 2 + $0.count } ?? 0)
            + (signedPeerRecordByteCount.map { 2 + $0 } ?? 0)
    }

    // MARK: - Decoding

    /// Decodes IdentifyInfo from protobuf wire format.
    static func decode(_ data: Data) throws -> IdentifyInfo {
        try data.withUnsafeBytes { bytes in
            var publicKey: PublicKey?
            var listenAddresses: [Multiaddr] = []
            var protocols: [String] = []
            var observedAddress: Multiaddr?
            var protocolVersion: String?
            var agentVersion: String?
            var signedPeerRecord: Envelope?

            var offset = 0

            while offset < bytes.count {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(wireType: wireType, buffer: bytes, offset: offset)
                    continue
                }

                let (lengthValue, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                offset += lengthBytes
                let length = try Varint.toInt(lengthValue)

                let fieldEnd = offset + length
                guard fieldEnd <= bytes.count else {
                    throw IdentifyError.invalidProtobuf("Field truncated")
                }

                switch fieldNumber {
                case 1: // publicKey
                    do {
                        publicKey = try PublicKey(protobufEncoded: data[fieldRange(in: data, offset: offset, end: fieldEnd)])
                    } catch {
                        print("[IdentifyProtobuf] Failed to decode publicKey: \(error)")
                        throw IdentifyError.invalidProtobuf("publicKey decode failed: \(error)")
                    }

                case 2: // listenAddrs
                    do {
                        let addr = try Multiaddr(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)])
                        listenAddresses.append(addr)
                    } catch {
                        // listenAddrs is repeated/optional, skip invalid entries
                        print("[IdentifyProtobuf] WARNING: Failed to decode listenAddr: \(error), skipping")
                    }

                case 3: // protocols
                    if let proto = String(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)], encoding: .utf8) {
                        protocols.append(proto)
                    }

                case 4: // observedAddr
                    do {
                        observedAddress = try Multiaddr(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)])
                    } catch {
                        // observedAddr is optional, skip if decode fails
                        print("[IdentifyProtobuf] WARNING: Failed to decode observedAddr: \(error), skipping")
                        observedAddress = nil
                    }

                case 5: // protocolVersion
                    protocolVersion = String(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)], encoding: .utf8)

                case 6: // agentVersion
                    agentVersion = String(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)], encoding: .utf8)

                case 8: // signedPeerRecord
                    do {
                        signedPeerRecord = try Envelope.unmarshal(data[fieldRange(in: data, offset: offset, end: fieldEnd)])
                    } catch {
                        // signedPeerRecord is optional, log and skip if decode fails
                        print("[IdentifyProtobuf] WARNING: Failed to decode signedPeerRecord: \(error), continuing without it")
                        signedPeerRecord = nil
                    }

                default:
                    break
                }

                offset = fieldEnd
            }

            return IdentifyInfo(
                publicKey: publicKey,
                listenAddresses: listenAddresses,
                protocols: protocols,
                observedAddress: observedAddress,
                protocolVersion: protocolVersion,
                agentVersion: agentVersion,
                signedPeerRecord: signedPeerRecord
            )
        }
    }

    private static func fieldRange(in data: Data, offset: Int, end: Int) -> Range<Data.Index> {
        let startIndex = data.index(data.startIndex, offsetBy: offset)
        let endIndex = data.index(data.startIndex, offsetBy: end)
        return startIndex..<endIndex
    }

    private static func skipField(
        wireType: UInt64,
        buffer: UnsafeRawBufferPointer,
        offset: Int
    ) throws -> Int {
        var newOffset = offset

        switch wireType {
        case 0:
            let (_, bytesRead) = try Varint.decode(from: buffer, at: newOffset)
            newOffset += bytesRead
        case 1:
            newOffset += 8
        case 5:
            newOffset += 4
        default:
            throw IdentifyError.invalidProtobuf("Unexpected wire type \(wireType)")
        }

        guard newOffset <= buffer.count else {
            throw IdentifyError.invalidProtobuf("Field truncated")
        }

        return newOffset
    }
}
