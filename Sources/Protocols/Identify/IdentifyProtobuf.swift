/// IdentifyProtobuf - Wire format encoding/decoding for Identify protocol
import Foundation
import NIOCore
import P2PCore
import Logging

private let identifyProtobufLogger = Logger(label: "swift-libp2p.IdentifyProtobuf")

/// Protobuf encoding/decoding for Identify messages.
///
/// The wire framing lives in the Embedded-clean ``IdentifyFields`` codec
/// (`LibP2PCore`); this adapter bridges the domain types — `PublicKey`,
/// `Multiaddr`, and the `Envelope` signed peer record — to/from the codec's raw
/// `[UInt8]` fields, and restores the historical `Data`/`ByteBuffer` API.
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

    // MARK: - Encoding

    /// Encodes IdentifyInfo to protobuf wire format.
    static func encode(_ info: IdentifyInfo) throws -> Data {
        let signedPeerRecordBytes = try info.signedPeerRecord?.marshal()

        let fields = IdentifyFields(
            publicKey: info.publicKey.map { [UInt8]($0.protobufEncoded) },
            listenAddrs: info.listenAddresses.map { [UInt8]($0.bytes) },
            protocols: info.protocols,
            observedAddr: info.observedAddress.map { [UInt8]($0.bytes) },
            protocolVersion: info.protocolVersion,
            agentVersion: info.agentVersion,
            signedPeerRecord: signedPeerRecordBytes.map { [UInt8]($0) }
        )
        return Data(fields.encode())
    }

    static func encode(_ info: IdentifyInfo, into buffer: inout ByteBuffer) throws {
        buffer.writeBytes(try encode(info))
    }

    // MARK: - Decoding

    /// Decodes IdentifyInfo from protobuf wire format.
    static func decode(_ data: Data) throws -> IdentifyInfo {
        let fields: IdentifyFields
        do {
            fields = try IdentifyFields.decode(from: [UInt8](data))
        } catch {
            // Map the typed codec error to the adapter's error contract.
            switch error {
            case .truncated:
                throw IdentifyError.invalidProtobuf("Field truncated")
            case .fieldTooLarge(let size, let max):
                throw IdentifyError.messageTooLarge(size: Int(clamping: size), max: max)
            case .unexpectedWireType(let wireType):
                throw IdentifyError.invalidProtobuf("Unexpected wire type \(wireType)")
            }
        }

        // Bridge the raw byte fields back into domain types. Per the historical
        // decoder, malformed optional/repeated entries (listenAddr, observedAddr,
        // signedPeerRecord) are logged and skipped rather than failing the whole
        // message; only a malformed publicKey is fatal.
        var publicKey: PublicKey?
        if let keyBytes = fields.publicKey {
            do {
                publicKey = try PublicKey(protobufEncoded: Data(keyBytes))
            } catch {
                identifyProtobufLogger.error("Failed to decode publicKey: \(String(describing: error))")
                throw IdentifyError.invalidProtobuf("publicKey decode failed: \(error)")
            }
        }

        var listenAddresses: [Multiaddr] = []
        for addrBytes in fields.listenAddrs {
            do {
                listenAddresses.append(try Multiaddr(bytes: Data(addrBytes)))
            } catch {
                // listenAddrs is repeated/optional, skip invalid entries
                identifyProtobufLogger.warning("Failed to decode listenAddr, skipping: \(String(describing: error))")
            }
        }

        var observedAddress: Multiaddr?
        if let observedBytes = fields.observedAddr {
            do {
                observedAddress = try Multiaddr(bytes: Data(observedBytes))
            } catch {
                // observedAddr is optional, skip if decode fails
                identifyProtobufLogger.warning("Failed to decode observedAddr, skipping: \(String(describing: error))")
                observedAddress = nil
            }
        }

        var signedPeerRecord: Envelope?
        if let recordBytes = fields.signedPeerRecord {
            do {
                signedPeerRecord = try Envelope.unmarshal(Data(recordBytes))
            } catch {
                // signedPeerRecord is optional, log and skip if decode fails
                identifyProtobufLogger.warning("Failed to decode signedPeerRecord, continuing without it: \(String(describing: error))")
                signedPeerRecord = nil
            }
        }

        return IdentifyInfo(
            publicKey: publicKey,
            listenAddresses: listenAddresses,
            protocols: fields.protocols,
            observedAddress: observedAddress,
            protocolVersion: fields.protocolVersion,
            agentVersion: fields.agentVersion,
            signedPeerRecord: signedPeerRecord
        )
    }

    static func decode(_ buffer: ByteBuffer) throws -> IdentifyInfo {
        try decode(Data(buffer: buffer))
    }
}
