/// KademliaProtobuf - Wire format encoding/decoding for Kademlia DHT.
///
/// Implements protobuf encoding/decoding for Kademlia messages.
///
/// See: https://github.com/libp2p/specs/tree/master/kad-dht

import Foundation
import P2PCore
import NIOCore

/// Protobuf encoding/decoding for Kademlia messages.
enum KademliaProtobuf {

    private struct PreparedPeer {
        let idBytes: Data
        let addressBytes: [Data]
        let connectionTypeRawValue: UInt64
        let encodedSize: Int
    }

    private struct PreparedRecord {
        let key: Data
        let value: Data
        let timeData: Data?
        let encodedSize: Int
    }

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
        var data = Data(capacity: estimatedCapacity(of: message))
        encode(message, into: &data)
        return data
    }

    static func encode(_ message: KademliaMessage, into data: inout Data) {
        data.reserveCapacity(data.count + estimatedCapacity(of: message))

        data.append(MessageTag.type)
        Varint.encode(UInt64(message.type.rawValue), into: &data)

        if let key = message.key {
            data.append(MessageTag.key)
            Varint.encode(UInt64(key.count), into: &data)
            data.append(key)
        }

        if let record = message.record {
            let preparedRecord = prepare(record)
            data.append(MessageTag.record)
            Varint.encode(UInt64(preparedRecord.encodedSize), into: &data)
            encodeRecord(preparedRecord, into: &data)
        }

        for peer in message.closerPeers {
            let preparedPeer = prepare(peer)
            data.append(MessageTag.closerPeers)
            Varint.encode(UInt64(preparedPeer.encodedSize), into: &data)
            encodePeer(preparedPeer, into: &data)
        }

        for peer in message.providerPeers {
            let preparedPeer = prepare(peer)
            data.append(MessageTag.providerPeers)
            Varint.encode(UInt64(preparedPeer.encodedSize), into: &data)
            encodePeer(preparedPeer, into: &data)
        }
    }

    static func encode(_ message: KademliaMessage, into buffer: inout ByteBuffer) {
        buffer.reserveCapacity(buffer.writerIndex + estimatedCapacity(of: message))

        buffer.writeInteger(MessageTag.type)
        Varint.encode(UInt64(message.type.rawValue), into: &buffer)

        if let key = message.key {
            buffer.writeInteger(MessageTag.key)
            Varint.encode(UInt64(key.count), into: &buffer)
            buffer.writeBytes(key)
        }

        if let record = message.record {
            let preparedRecord = prepare(record)
            buffer.writeInteger(MessageTag.record)
            Varint.encode(UInt64(preparedRecord.encodedSize), into: &buffer)
            encodeRecord(preparedRecord, into: &buffer)
        }

        for peer in message.closerPeers {
            let preparedPeer = prepare(peer)
            buffer.writeInteger(MessageTag.closerPeers)
            Varint.encode(UInt64(preparedPeer.encodedSize), into: &buffer)
            encodePeer(preparedPeer, into: &buffer)
        }

        for peer in message.providerPeers {
            let preparedPeer = prepare(peer)
            buffer.writeInteger(MessageTag.providerPeers)
            Varint.encode(UInt64(preparedPeer.encodedSize), into: &buffer)
            encodePeer(preparedPeer, into: &buffer)
        }
    }

    private static func estimatedCapacity(of message: KademliaMessage) -> Int {
        12
            + (message.key.map { 10 + $0.count } ?? 0)
            + (message.record.map { 10 + $0.key.count + $0.value.count + 20 } ?? 0)
            + message.closerPeers.count * 100
            + message.providerPeers.count * 100
    }

    /// Decodes a KademliaMessage from protobuf wire format.
    static func decode(_ data: Data) throws -> KademliaMessage {
        var type: KademliaMessageType = .findNode
        var key: Data?
        var record: KademliaRecord?
        var closerPeers: [KademliaPeer] = []
        var providerPeers: [KademliaPeer] = []

        var offset = 0

        while offset < data.count {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeVarint): // type
                let (value, valueBytes) = try Varint.decode(from: data, at: offset)
                offset += valueBytes
                type = KademliaMessageType(rawValue: UInt32(value)) ?? .findNode

            case (10, wireTypeLengthDelimited): // key
                let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let length = try Varint.toInt(lengthValue)
                let fieldEnd = offset + length
                guard fieldEnd <= data.count else {
                    throw KademliaError.encodingError("Key field truncated")
                }
                key = Data(data[fieldRange(in: data, offset: offset, end: fieldEnd)])
                offset = fieldEnd

            case (3, wireTypeLengthDelimited): // record
                let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let length = try Varint.toInt(lengthValue)
                let fieldEnd = offset + length
                guard fieldEnd <= data.count else {
                    throw KademliaError.encodingError("Record field truncated")
                }
                record = try decodeRecord(data[fieldRange(in: data, offset: offset, end: fieldEnd)])
                offset = fieldEnd

            case (8, wireTypeLengthDelimited): // closerPeers
                let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let length = try Varint.toInt(lengthValue)
                let fieldEnd = offset + length
                guard fieldEnd <= data.count else {
                    throw KademliaError.encodingError("CloserPeers field truncated")
                }
                let peer = try decodePeer(data[fieldRange(in: data, offset: offset, end: fieldEnd)])
                closerPeers.append(peer)
                offset = fieldEnd

            case (9, wireTypeLengthDelimited): // providerPeers
                let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let length = try Varint.toInt(lengthValue)
                let fieldEnd = offset + length
                guard fieldEnd <= data.count else {
                    throw KademliaError.encodingError("ProviderPeers field truncated")
                }
                let peer = try decodePeer(data[fieldRange(in: data, offset: offset, end: fieldEnd)])
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
            if closerPeers.isEmpty, let key {
                return .findNode(key: key)
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

    private static func encodePeer(_ peer: PreparedPeer, into data: inout Data) {
        data.append(PeerTag.id)
        Varint.encode(UInt64(peer.idBytes.count), into: &data)
        data.append(peer.idBytes)

        for addrBytes in peer.addressBytes {
            data.append(PeerTag.addrs)
            Varint.encode(UInt64(addrBytes.count), into: &data)
            data.append(addrBytes)
        }

        data.append(PeerTag.connection)
        Varint.encode(peer.connectionTypeRawValue, into: &data)
    }

    private static func encodePeer(_ peer: PreparedPeer, into buffer: inout ByteBuffer) {
        buffer.writeInteger(PeerTag.id)
        Varint.encode(UInt64(peer.idBytes.count), into: &buffer)
        buffer.writeBytes(peer.idBytes)

        for addrBytes in peer.addressBytes {
            buffer.writeInteger(PeerTag.addrs)
            Varint.encode(UInt64(addrBytes.count), into: &buffer)
            buffer.writeBytes(addrBytes)
        }

        buffer.writeInteger(PeerTag.connection)
        Varint.encode(peer.connectionTypeRawValue, into: &buffer)
    }

    private static func decodePeer(_ data: Data) throws -> KademliaPeer {
        var id: PeerID?
        var addresses: [Multiaddr] = []
        var connectionType: KademliaPeerConnectionType = .notConnected

        var offset = 0

        while offset < data.count {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeLengthDelimited): // id
                let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let length = try Varint.toInt(lengthValue)
                let fieldEnd = offset + length
                guard fieldEnd <= data.count else {
                    throw KademliaError.encodingError("Peer ID truncated")
                }
                id = try PeerID(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)])
                offset = fieldEnd

            case (2, wireTypeLengthDelimited): // addrs
                let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let length = try Varint.toInt(lengthValue)
                let fieldEnd = offset + length
                guard fieldEnd <= data.count else {
                    throw KademliaError.encodingError("Address truncated")
                }
                let addr = try Multiaddr(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)])
                addresses.append(addr)
                offset = fieldEnd

            case (3, wireTypeVarint): // connection
                let (value, valueBytes) = try Varint.decode(from: data, at: offset)
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

    private static func encodeRecord(_ record: PreparedRecord, into data: inout Data) {
        data.append(RecordTag.key)
        Varint.encode(UInt64(record.key.count), into: &data)
        data.append(record.key)

        data.append(RecordTag.value)
        Varint.encode(UInt64(record.value.count), into: &data)
        data.append(record.value)

        if let timeData = record.timeData {
            data.append(RecordTag.timeReceived)
            Varint.encode(UInt64(timeData.count), into: &data)
            data.append(timeData)
        }
    }

    private static func encodeRecord(_ record: PreparedRecord, into buffer: inout ByteBuffer) {
        buffer.writeInteger(RecordTag.key)
        Varint.encode(UInt64(record.key.count), into: &buffer)
        buffer.writeBytes(record.key)

        buffer.writeInteger(RecordTag.value)
        Varint.encode(UInt64(record.value.count), into: &buffer)
        buffer.writeBytes(record.value)

        if let timeData = record.timeData {
            buffer.writeInteger(RecordTag.timeReceived)
            Varint.encode(UInt64(timeData.count), into: &buffer)
            buffer.writeBytes(timeData)
        }
    }

    private static func encodedSize(of message: KademliaMessage) -> Int {
        2
            + (message.key.map { 1 + varintSize(of: $0.count) + $0.count } ?? 0)
            + (message.record.map { 1 + varintSize(of: encodedSize(of: $0)) + encodedSize(of: $0) } ?? 0)
            + message.closerPeers.reduce(0) { total, peer in
                let peerSize = encodedSize(of: peer)
                return total + 1 + varintSize(of: peerSize) + peerSize
            }
            + message.providerPeers.reduce(0) { total, peer in
                let peerSize = encodedSize(of: peer)
                return total + 1 + varintSize(of: peerSize) + peerSize
        }
    }

    private static func prepare(_ peer: KademliaPeer) -> PreparedPeer {
        let idBytes = peer.id.bytes
        let addressBytes = peer.addresses.map(\.bytes)
        let addressSize = addressBytes.reduce(0) { total, addrBytes in
            total + 1 + varintSize(of: addrBytes.count) + addrBytes.count
        }
        return PreparedPeer(
            idBytes: idBytes,
            addressBytes: addressBytes,
            connectionTypeRawValue: UInt64(peer.connectionType.rawValue),
            encodedSize: 1 + varintSize(of: idBytes.count) + idBytes.count + addressSize + 1 + 1
        )
    }

    private static func prepare(_ record: KademliaRecord) -> PreparedRecord {
        let timeData = record.timeReceived.map { Data($0.utf8) }
        let timeSize = timeData.map { 1 + varintSize(of: $0.count) + $0.count } ?? 0
        return PreparedRecord(
            key: record.key,
            value: record.value,
            timeData: timeData,
            encodedSize: 1 + varintSize(of: record.key.count) + record.key.count
                + 1 + varintSize(of: record.value.count) + record.value.count
                + timeSize
        )
    }

    private static func encodedSize(of peer: KademliaPeer) -> Int {
        let idBytes = peer.id.bytes
        let addressBytes = peer.addresses.reduce(0) { total, addr in
            total + 1 + varintSize(of: addr.bytes.count) + addr.bytes.count
        }
        return 1 + varintSize(of: idBytes.count) + idBytes.count
            + addressBytes
            + 1 + 1
    }

    private static func encodedSize(of record: KademliaRecord) -> Int {
        let timeSize: Int
        if let timeReceived = record.timeReceived {
            let count = Data(timeReceived.utf8).count
            timeSize = 1 + varintSize(of: count) + count
        } else {
            timeSize = 0
        }

        return 1 + varintSize(of: record.key.count) + record.key.count
            + 1 + varintSize(of: record.value.count) + record.value.count
            + timeSize
    }

    private static func varintSize(of count: Int) -> Int {
        var value = UInt64(count)
        var size = 1
        while value >= 0x80 {
            value >>= 7
            size += 1
        }
        return size
    }

    private static func decodeRecord(_ data: Data) throws -> KademliaRecord {
        var key: Data?
        var value: Data?
        var timeReceived: String?

        var offset = 0

        while offset < data.count {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(wireType: wireType, data: data, offset: offset)
                continue
            }

            let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
            offset += lengthBytes
            let length = try Varint.toInt(lengthValue)
            let fieldEnd = offset + length
            guard fieldEnd <= data.count else {
                throw KademliaError.encodingError("Record field truncated")
            }

            switch fieldNumber {
            case 1: // key
                key = Data(data[fieldRange(in: data, offset: offset, end: fieldEnd)])
            case 2: // value
                value = Data(data[fieldRange(in: data, offset: offset, end: fieldEnd)])
            case 5: // timeReceived
                timeReceived = String(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)], encoding: .utf8)
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
            let (_, varBytes) = try Varint.decode(from: data, at: newOffset)
            newOffset += varBytes
        case 1: // 64-bit
            newOffset += 8
        case 2: // Length-delimited
            let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: newOffset)
            let length = try Varint.toInt(lengthValue)
            newOffset += lengthBytes + length
        case 5: // 32-bit
            newOffset += 4
        default:
            throw KademliaError.encodingError("Unknown wire type \(wireType)")
        }

        guard newOffset <= data.count else {
            throw KademliaError.encodingError("Field extends beyond data")
        }

        return newOffset
    }

    private static func fieldRange(in data: Data, offset: Int, end: Int) -> Range<Data.Index> {
        let startIndex = data.index(data.startIndex, offsetBy: offset)
        let endIndex = data.index(data.startIndex, offsetBy: end)
        return startIndex..<endIndex
    }
}
