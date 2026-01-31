/// CYCLON protobuf wire format encoding and decoding.
///
/// Wire format (hand-written protobuf, matching GossipSub pattern):
///
/// ```
/// message CyclonEntry {
///     bytes peer_id = 1;
///     repeated bytes addrs = 2;
///     uint64 age = 3;
/// }
///
/// message CyclonShuffleRequest {
///     repeated CyclonEntry entries = 1;
/// }
///
/// message CyclonShuffleResponse {
///     repeated CyclonEntry entries = 1;
/// }
///
/// message CyclonMessage {
///     oneof payload {
///         CyclonShuffleRequest request = 1;
///         CyclonShuffleResponse response = 2;
///     }
/// }
/// ```

import Foundation
import P2PCore

public enum CYCLONProtobuf {

    // MARK: - Encoding

    /// Encodes a CYCLON message for wire transmission.
    public static func encode(_ message: CYCLONMessage) -> Data {
        switch message {
        case .shuffleRequest(let entries):
            let inner = encodeEntries(entries)
            // Field 1 (request): length-delimited
            return encodeField(fieldNumber: 1, data: inner)

        case .shuffleResponse(let entries):
            let inner = encodeEntries(entries)
            // Field 2 (response): length-delimited
            return encodeField(fieldNumber: 2, data: inner)
        }
    }

    /// Decodes a CYCLON message from wire bytes.
    public static func decode(_ data: Data) throws -> CYCLONMessage {
        var offset = data.startIndex
        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == 2 else {
                throw CYCLONError.decodingFailed("unexpected wire type \(wireType)")
            }

            let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            guard fieldEnd <= data.endIndex else {
                throw CYCLONError.decodingFailed("field extends beyond data")
            }
            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1:
                let entries = try decodeEntries(fieldData)
                return .shuffleRequest(entries: entries)
            case 2:
                let entries = try decodeEntries(fieldData)
                return .shuffleResponse(entries: entries)
            default:
                continue
            }
        }
        throw CYCLONError.decodingFailed("no message payload found")
    }

    // MARK: - Entry Encoding

    private static func encodeEntries(_ entries: [CYCLONEntry]) -> Data {
        var result = Data()
        for entry in entries {
            let entryData = encodeEntry(entry)
            // Repeated field 1: length-delimited
            result.append(contentsOf: encodeField(fieldNumber: 1, data: entryData))
        }
        return result
    }

    private static func encodeEntry(_ entry: CYCLONEntry) -> Data {
        var result = Data()

        // Field 1: peer_id (bytes)
        let peerIDBytes = entry.peerID.bytes
        result.append(contentsOf: encodeField(fieldNumber: 1, data: peerIDBytes))

        // Field 2: addrs (repeated bytes)
        for addr in entry.addresses {
            result.append(contentsOf: encodeField(fieldNumber: 2, data: addr.bytes))
        }

        // Field 3: age (varint)
        result.append(UInt8((3 << 3) | 0))
        result.append(contentsOf: Varint.encode(entry.age))

        return result
    }

    // MARK: - Entry Decoding

    private static func decodeEntries(_ data: Data) throws -> [CYCLONEntry] {
        var entries: [CYCLONEntry] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard fieldNumber == 1, wireType == 2 else {
                throw CYCLONError.decodingFailed("expected entry field")
            }

            let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            guard fieldEnd <= data.endIndex else {
                throw CYCLONError.decodingFailed("entry extends beyond data")
            }
            let entryData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            let entry = try decodeEntry(entryData)
            entries.append(entry)
        }
        return entries
    }

    private static func decodeEntry(_ data: Data) throws -> CYCLONEntry {
        var peerIDBytes: Data?
        var addresses: [Multiaddr] = []
        var age: UInt64 = 0

        var offset = data.startIndex
        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, 2): // peer_id
                let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw CYCLONError.decodingFailed("peer_id extends beyond data")
                }
                peerIDBytes = Data(data[offset..<fieldEnd])
                offset = fieldEnd

            case (2, 2): // addr
                let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw CYCLONError.decodingFailed("addr extends beyond data")
                }
                let addrBytes = Data(data[offset..<fieldEnd])
                offset = fieldEnd
                let addr = try Multiaddr(bytes: addrBytes)
                addresses.append(addr)

            case (3, 0): // age
                let (value, valueBytes) = try Varint.decode(from: data, at: offset)
                offset += valueBytes
                age = value

            default:
                throw CYCLONError.decodingFailed("unknown field \(fieldNumber) wireType \(wireType)")
            }
        }

        guard let pidBytes = peerIDBytes else {
            throw CYCLONError.decodingFailed("missing peer_id")
        }

        let peerID = try PeerID(bytes: pidBytes)
        return CYCLONEntry(peerID: peerID, addresses: addresses, age: age)
    }

    // MARK: - Helpers

    private static func encodeField(fieldNumber: UInt64, data: Data) -> Data {
        var result = Data()
        let tag = UInt8((fieldNumber << 3) | 2)
        result.append(tag)
        result.append(contentsOf: Varint.encode(UInt64(data.count)))
        result.append(data)
        return result
    }
}
