/// IdentifyProtobuf - Wire format encoding/decoding for Identify protocol
import Foundation
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
    static func encode(_ info: IdentifyInfo) -> Data {
        var result = Data()

        // Field 1: publicKey (optional bytes)
        if let publicKey = info.publicKey {
            let bytes = publicKey.protobufEncoded
            result.append(tagPublicKey)
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 2: listenAddrs (repeated bytes)
        for addr in info.listenAddresses {
            let bytes = addr.bytes
            result.append(tagListenAddrs)
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 3: protocols (repeated string)
        for proto in info.protocols {
            let bytes = Data(proto.utf8)
            result.append(tagProtocols)
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 4: observedAddr (optional bytes)
        if let observed = info.observedAddress {
            let bytes = observed.bytes
            result.append(tagObservedAddr)
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 5: protocolVersion (optional string)
        if let version = info.protocolVersion {
            let bytes = Data(version.utf8)
            result.append(tagProtocolVersion)
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 6: agentVersion (optional string)
        if let agent = info.agentVersion {
            let bytes = Data(agent.utf8)
            result.append(tagAgentVersion)
            result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
            result.append(bytes)
        }

        // Field 8: signedPeerRecord (optional bytes)
        if let envelope = info.signedPeerRecord {
            if let bytes = try? envelope.marshal() {
                result.append(tagSignedPeerRecord)
                result.append(contentsOf: Varint.encode(UInt64(bytes.count)))
                result.append(bytes)
            }
        }

        return result
    }

    // MARK: - Decoding

    /// Decodes IdentifyInfo from protobuf wire format.
    static func decode(_ data: Data) throws -> IdentifyInfo {
        var publicKey: PublicKey?
        var listenAddresses: [Multiaddr] = []
        var protocols: [String] = []
        var observedAddress: Multiaddr?
        var protocolVersion: String?
        var agentVersion: String?
        var signedPeerRecord: Envelope?

        var offset = data.startIndex

        while offset < data.endIndex {
            // Read field tag
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            // All our fields are length-delimited (wire type 2)
            guard wireType == wireTypeLengthDelimited else {
                // Skip unknown wire types
                if wireType == 0 {
                    // Varint - read and discard
                    let (_, varBytes) = try Varint.decode(Data(data[offset...]))
                    offset += varBytes
                } else if wireType == 1 {
                    // 64-bit - skip 8 bytes
                    offset += 8
                } else if wireType == 5 {
                    // 32-bit - skip 4 bytes
                    offset += 4
                } else {
                    throw IdentifyError.invalidProtobuf("Unexpected wire type \(wireType)")
                }
                continue
            }

            // Read field length
            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes

            let fieldEnd = offset + Int(length)
            guard fieldEnd <= data.endIndex else {
                throw IdentifyError.invalidProtobuf("Field truncated")
            }

            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1: // publicKey
                publicKey = try? PublicKey(protobufEncoded: fieldData)

            case 2: // listenAddrs
                if let addr = try? Multiaddr(bytes: fieldData) {
                    listenAddresses.append(addr)
                }

            case 3: // protocols
                if let proto = String(data: fieldData, encoding: .utf8) {
                    protocols.append(proto)
                }

            case 4: // observedAddr
                observedAddress = try? Multiaddr(bytes: fieldData)

            case 5: // protocolVersion
                protocolVersion = String(data: fieldData, encoding: .utf8)

            case 6: // agentVersion
                agentVersion = String(data: fieldData, encoding: .utf8)

            case 8: // signedPeerRecord
                signedPeerRecord = try? Envelope.unmarshal(fieldData)

            default:
                // Skip unknown fields
                break
            }
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
