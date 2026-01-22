/// KademliaProtobuf - Wire format encoding/decoding for Kademlia DHT.
///
/// Implements protobuf encoding/decoding for Kademlia messages.
///
/// See: https://github.com/libp2p/specs/tree/master/kad-dht

import Foundation
import P2PCore

/// Protobuf encoding/decoding for Kademlia messages.
enum KademliaProtobuf {

    // MARK: - Wire Type Constants

    private static let wireTypeVarint: UInt64 = 0
    private static let wireTypeLengthDelimited: UInt64 = 2

    // MARK: - Message Field Tags

    private enum MessageTag {
        static let type: UInt8 = 0x08        // field 1, varint
        static let key: UInt8 = 0x52         // field 10, length-delimited
        static let record: UInt8 = 0x1A      // field 3, length-delimited
        static let closerPeers: UInt8 = 0x42 // field 8, length-delimited (repeated)
        static let providerPeers: UInt8 = 0x4A // field 9, length-delimited (repeated)
    }

    // MARK: - Peer Field Tags

    private enum PeerTag {
        static let id: UInt8 = 0x0A          // field 1, length-delimited
        static let addrs: UInt8 = 0x12       // field 2, length-delimited (repeated)
        static let connection: UInt8 = 0x18  // field 3, varint
    }

    // MARK: - Record Field Tags

    private enum RecordTag {
        static let key: UInt8 = 0x0A         // field 1, length-delimited
        static let value: UInt8 = 0x12       // field 2, length-delimited
        static let timeReceived: UInt8 = 0x2A // field 5, length-delimited (string)
    }

    // MARK: - Message Encoding

    /// Encodes a KademliaMessage to protobuf wire format.
    static func encode(_ message: KademliaMessage) -> Data {
        var result = Data()

        // Field 1: type (varint)
        result.append(MessageTag.type)
        result.append(contentsOf: Varint.encode(UInt64(message.type.rawValue)))

        // Field 10: key (optional bytes)
        if let key = message.key {
            result.append(MessageTag.key)
            result.append(contentsOf: Varint.encode(UInt64(key.count)))
            result.append(key)
        }

        // Field 3: record (optional embedded message)
        if let record = message.record {
            let recordData = encodeRecord(record)
            result.append(MessageTag.record)
            result.append(contentsOf: Varint.encode(UInt64(recordData.count)))
            result.append(recordData)
        }

        // Field 8: closerPeers (repeated embedded message)
        for peer in message.closerPeers {
            let peerData = encodePeer(peer)
            result.append(MessageTag.closerPeers)
            result.append(contentsOf: Varint.encode(UInt64(peerData.count)))
            result.append(peerData)
        }

        // Field 9: providerPeers (repeated embedded message)
        for peer in message.providerPeers {
            let peerData = encodePeer(peer)
            result.append(MessageTag.providerPeers)
            result.append(contentsOf: Varint.encode(UInt64(peerData.count)))
            result.append(peerData)
        }

        return result
    }

    /// Decodes a KademliaMessage from protobuf wire format.
    static func decode(_ data: Data) throws -> KademliaMessage {
        var type: KademliaMessageType = .findNode
        var key: Data?
        var record: KademliaRecord?
        var closerPeers: [KademliaPeer] = []
        var providerPeers: [KademliaPeer] = []

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeVarint): // type
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
                offset += valueBytes
                type = KademliaMessageType(rawValue: UInt32(value)) ?? .findNode

            case (10, wireTypeLengthDelimited): // key
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw KademliaError.encodingError("Key field truncated")
                }
                key = Data(data[offset..<fieldEnd])
                offset = fieldEnd

            case (3, wireTypeLengthDelimited): // record
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw KademliaError.encodingError("Record field truncated")
                }
                record = try decodeRecord(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (8, wireTypeLengthDelimited): // closerPeers
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw KademliaError.encodingError("CloserPeers field truncated")
                }
                let peer = try decodePeer(Data(data[offset..<fieldEnd]))
                closerPeers.append(peer)
                offset = fieldEnd

            case (9, wireTypeLengthDelimited): // providerPeers
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw KademliaError.encodingError("ProviderPeers field truncated")
                }
                let peer = try decodePeer(Data(data[offset..<fieldEnd]))
                providerPeers.append(peer)
                offset = fieldEnd

            default:
                // Skip unknown fields
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        // Construct message based on type
        switch type {
        case .findNode:
            if closerPeers.isEmpty && key != nil {
                return .findNode(key: key!)
            }
            return .findNodeResponse(closerPeers: closerPeers)

        case .getValue:
            if record != nil || !closerPeers.isEmpty {
                return .getValueResponse(record: record, closerPeers: closerPeers)
            }
            guard let key = key else {
                throw KademliaError.encodingError("Missing key in GET_VALUE")
            }
            return .getValue(key: key)

        case .putValue:
            guard let record = record else {
                throw KademliaError.encodingError("Missing record in PUT_VALUE")
            }
            return .putValue(record: record)

        case .addProvider:
            guard let key = key else {
                throw KademliaError.encodingError("Missing key in ADD_PROVIDER")
            }
            return .addProvider(key: key, providers: providerPeers)

        case .getProviders:
            if !providerPeers.isEmpty || !closerPeers.isEmpty {
                return .getProvidersResponse(providers: providerPeers, closerPeers: closerPeers)
            }
            guard let key = key else {
                throw KademliaError.encodingError("Missing key in GET_PROVIDERS")
            }
            return .getProviders(key: key)

        case .ping:
            throw KademliaError.protocolViolation("PING is deprecated")
        }
    }

    // MARK: - Peer Encoding

    private static func encodePeer(_ peer: KademliaPeer) -> Data {
        var result = Data()

        // Field 1: id (bytes)
        let idBytes = peer.id.bytes
        result.append(PeerTag.id)
        result.append(contentsOf: Varint.encode(UInt64(idBytes.count)))
        result.append(idBytes)

        // Field 2: addrs (repeated bytes)
        for addr in peer.addresses {
            let addrBytes = addr.bytes
            result.append(PeerTag.addrs)
            result.append(contentsOf: Varint.encode(UInt64(addrBytes.count)))
            result.append(addrBytes)
        }

        // Field 3: connection (varint)
        result.append(PeerTag.connection)
        result.append(contentsOf: Varint.encode(UInt64(peer.connectionType.rawValue)))

        return result
    }

    private static func decodePeer(_ data: Data) throws -> KademliaPeer {
        var id: PeerID?
        var addresses: [Multiaddr] = []
        var connectionType: KademliaPeerConnectionType = .notConnected

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeLengthDelimited): // id
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw KademliaError.encodingError("Peer ID truncated")
                }
                id = try PeerID(bytes: Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (2, wireTypeLengthDelimited): // addrs
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw KademliaError.encodingError("Address truncated")
                }
                let addr = try Multiaddr(bytes: Data(data[offset..<fieldEnd]))
                addresses.append(addr)
                offset = fieldEnd

            case (3, wireTypeVarint): // connection
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
                offset += valueBytes
                connectionType = KademliaPeerConnectionType(rawValue: UInt32(value)) ?? .notConnected

            default:
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        guard let peerID = id else {
            throw KademliaError.encodingError("Missing peer ID")
        }

        return KademliaPeer(id: peerID, addresses: addresses, connectionType: connectionType)
    }

    // MARK: - Record Encoding

    private static func encodeRecord(_ record: KademliaRecord) -> Data {
        var result = Data()

        // Field 1: key (bytes)
        result.append(RecordTag.key)
        result.append(contentsOf: Varint.encode(UInt64(record.key.count)))
        result.append(record.key)

        // Field 2: value (bytes)
        result.append(RecordTag.value)
        result.append(contentsOf: Varint.encode(UInt64(record.value.count)))
        result.append(record.value)

        // Field 5: timeReceived (optional string)
        if let timeReceived = record.timeReceived {
            let timeData = Data(timeReceived.utf8)
            result.append(RecordTag.timeReceived)
            result.append(contentsOf: Varint.encode(UInt64(timeData.count)))
            result.append(timeData)
        }

        return result
    }

    private static func decodeRecord(_ data: Data) throws -> KademliaRecord {
        var key: Data?
        var value: Data?
        var timeReceived: String?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(wireType: wireType, data: data, offset: offset)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            guard fieldEnd <= data.endIndex else {
                throw KademliaError.encodingError("Record field truncated")
            }

            switch fieldNumber {
            case 1: // key
                key = Data(data[offset..<fieldEnd])
            case 2: // value
                value = Data(data[offset..<fieldEnd])
            case 5: // timeReceived
                timeReceived = String(data: Data(data[offset..<fieldEnd]), encoding: .utf8)
            default:
                break
            }
            offset = fieldEnd
        }

        guard let recordKey = key, let recordValue = value else {
            throw KademliaError.encodingError("Missing key or value in record")
        }

        return KademliaRecord(key: recordKey, value: recordValue, timeReceived: timeReceived)
    }

    // MARK: - Helpers

    private static func skipField(wireType: UInt64, data: Data, offset: Int) throws -> Int {
        var newOffset = offset

        switch wireType {
        case 0: // Varint
            let (_, varBytes) = try Varint.decode(Data(data[newOffset...]))
            newOffset += varBytes
        case 1: // 64-bit
            newOffset += 8
        case 2: // Length-delimited
            let (length, lengthBytes) = try Varint.decode(Data(data[newOffset...]))
            newOffset += lengthBytes + Int(length)
        case 5: // 32-bit
            newOffset += 4
        default:
            throw KademliaError.encodingError("Unknown wire type \(wireType)")
        }

        guard newOffset <= data.endIndex else {
            throw KademliaError.encodingError("Field extends beyond data")
        }

        return newOffset
    }
}
