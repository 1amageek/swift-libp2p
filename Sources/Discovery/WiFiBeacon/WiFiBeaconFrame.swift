import Foundation

/// Wire format for WiFi beacon UDP datagrams.
///
/// ```
/// +--------+--------+---------+-------+
/// | Magic (2B)      | Version | Flags |
/// | 0x50 0x32 ("P2")| 0x01    | 0x00  |
/// +--------+--------+---------+-------+
/// | Payload Length (2B, big-endian)    |
/// +------------------------------------+
/// | Reserved (2B, 0x00 0x00)          |
/// +------------------------------------+
/// | Beacon Payload (N bytes)           |
/// +------------------------------------+
/// ```
struct WiFiBeaconFrame: Sendable {
    static let magic0: UInt8 = 0x50  // 'P'
    static let magic1: UInt8 = 0x32  // '2'
    static let version: UInt8 = 0x01
    static let headerSize: Int = 8

    let payload: Data

    /// Encodes the frame into wire format.
    func encode() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        // Magic (2B)
        data.append(Self.magic0)
        data.append(Self.magic1)
        // Version (1B)
        data.append(Self.version)
        // Flags (1B)
        data.append(0x00)
        // Payload length (2B, big-endian)
        let length = UInt16(payload.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        // Reserved (2B)
        data.append(0x00)
        data.append(0x00)
        // Payload
        data.append(payload)
        return data
    }

    /// Decodes a frame from wire format.
    /// Returns nil if the data is malformed.
    static func decode(from data: Data) -> WiFiBeaconFrame? {
        guard data.count >= headerSize else { return nil }

        // Verify magic
        guard data[data.startIndex] == magic0,
              data[data.startIndex + 1] == magic1 else {
            return nil
        }

        // Verify version
        guard data[data.startIndex + 2] == version else { return nil }

        // Read payload length (big-endian UInt16)
        let lengthHi = UInt16(data[data.startIndex + 4])
        let lengthLo = UInt16(data[data.startIndex + 5])
        let payloadLength = Int((lengthHi << 8) | lengthLo)

        // Verify actual data length matches declared length
        guard data.count >= headerSize + payloadLength else { return nil }

        let payloadStart = data.startIndex + headerSize
        let payload = data[payloadStart..<(payloadStart + payloadLength)]
        return WiFiBeaconFrame(payload: Data(payload))
    }
}
