/// Multiaddr protocol-table and value codec (Embedded-clean).
/// https://github.com/multiformats/multiaddr/blob/master/protocols.csv
///
/// Embedded-clean: no Foundation, no `inet_pton`, no `any`, no `PeerID`. This is
/// the protocol table (code <-> name <-> requires-value) plus the binary value
/// encode/decode over `[UInt8]`. The `MultiaddrProtocol` enum — which carries a
/// `PeerID` in its `.p2p` case and `Data` in its physical-transport cases — and
/// the textual `String`<->`Data` surface stay in the `P2PCore` adapter, which
/// delegates IP/varint framing to this core.

/// The multiaddr protocol-table codec namespace.
public enum MultiaddrCodec {

    // MARK: - Protocol Codes

    /// Protocol codes as defined in the multiaddr spec (plus this project's
    /// custom physical-transport codes).
    public enum Code {
        public static let ip4: UInt64 = 4
        public static let tcp: UInt64 = 6
        public static let dns: UInt64 = 53
        public static let dns4: UInt64 = 54
        public static let dns6: UInt64 = 55
        public static let dnsaddr: UInt64 = 56
        public static let ip6: UInt64 = 41
        public static let ip6zone: UInt64 = 42
        public static let unix: UInt64 = 400
        public static let p2p: UInt64 = 421
        public static let udp: UInt64 = 273
        public static let p2pCircuit: UInt64 = 290
        public static let quic: UInt64 = 460
        public static let quicV1: UInt64 = 461
        public static let webrtcDirect: UInt64 = 276
        public static let ws: UInt64 = 477
        public static let wss: UInt64 = 478
        public static let webtransport: UInt64 = 480
        public static let certhash: UInt64 = 466
        public static let memory: UInt64 = 777   // custom: in-memory transport
        public static let ble: UInt64 = 0x01B0   // custom: BLE transport
        public static let wifiDirect: UInt64 = 0x01B1  // custom: WiFi Direct
        public static let lora: UInt64 = 0x01B2  // custom: LoRa transport
        public static let nfc: UInt64 = 0x01B3   // custom: NFC transport
    }

    // MARK: - Table Lookups

    /// Whether a protocol name requires a value component.
    ///
    /// - Parameter name: The protocol name (e.g. "ip4", "tcp", "quic").
    /// - Returns: `true` if a value is required, `false` if not, `nil` if the
    ///   name is unknown.
    public static func requiresValue(name: String) -> Bool? {
        switch name {
        case "ip4", "ip6zone", "ip6", "tcp", "udp", "p2p", "ipfs",
             "dns", "dns4", "dns6", "dnsaddr", "unix", "memory",
             "certhash", "ble", "wifi-direct", "lora", "nfc":
            return true
        case "quic", "quic-v1", "ws", "wss", "p2p-circuit", "webrtc-direct", "webtransport":
            return false
        default:
            return nil
        }
    }

    // MARK: - Value Encoding (IP / port)

    /// Encodes a dotted-decimal IPv4 address to its 4 wire bytes.
    /// - Returns: The 4 address bytes, or `nil` if invalid.
    public static func encodeIPv4Value(_ address: String) -> [UInt8]? {
        IPAddress.encodeIPv4(address)
    }

    /// Encodes an IPv6 address (zone suffix stripped) to its 16 wire bytes.
    /// - Returns: The 16 address bytes, or `nil` if invalid.
    public static func encodeIPv6Value(_ address: String) -> [UInt8]? {
        // Strip a trailing zone before encoding the binary form.
        let clean: String
        if let percentIndex = address.firstIndex(of: "%") {
            clean = String(address[..<percentIndex])
        } else {
            clean = address
        }
        guard !clean.isEmpty else { return nil }
        return IPAddress.encodeIPv6(clean)
    }

    /// Encodes a 16-bit port to its 2 big-endian wire bytes.
    public static func encodePort(_ port: UInt16) -> [UInt8] {
        [UInt8(port >> 8), UInt8(port & 0xFF)]
    }

    /// Encodes a length-delimited value: `varint(count) + bytes`.
    public static func encodeLengthDelimited(_ bytes: [UInt8]) -> [UInt8] {
        var result = Varint.encodeBytes(UInt64(bytes.count))
        result.append(contentsOf: bytes)
        return result
    }

    // MARK: - Value Decoding

    /// Decodes a fixed-size value field at `offset`, returning the raw bytes and
    /// the number of bytes consumed.
    ///
    /// - Throws: `MultiaddrCodecError.insufficientData` if out of bounds.
    public static func decodeFixed(
        _ bytes: [UInt8], at offset: Int, size: Int
    ) throws(MultiaddrCodecError) -> (value: [UInt8], consumed: Int) {
        guard offset >= 0, offset + size <= bytes.count else {
            throw .insufficientData
        }
        return (Array(bytes[offset..<(offset + size)]), size)
    }

    /// Decodes a length-delimited value field at `offset`: `varint(len) + bytes`.
    ///
    /// - Parameters:
    ///   - maxLength: Reject values whose declared length exceeds this bound.
    /// - Returns: The value bytes and the total number of bytes consumed
    ///   (length prefix + value).
    /// - Throws: `MultiaddrCodecError` on malformed or oversized input.
    public static func decodeLengthDelimited(
        _ bytes: [UInt8], at offset: Int, maxLength: Int
    ) throws(MultiaddrCodecError) -> (value: [UInt8], consumed: Int) {
        let length: UInt64
        let lengthBytes: Int
        do {
            (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
        } catch {
            throw .insufficientData
        }
        guard length <= UInt64(maxLength) else {
            throw .fieldTooLarge
        }
        let len = Int(length)
        let valueStart = offset + lengthBytes
        let valueEnd = valueStart + len
        guard valueEnd <= bytes.count else {
            throw .insufficientData
        }
        return (Array(bytes[valueStart..<valueEnd]), lengthBytes + len)
    }
}

/// Errors from the Multiaddr value codec.
public enum MultiaddrCodecError: Error, Equatable, Sendable {
    case insufficientData
    case fieldTooLarge
}
