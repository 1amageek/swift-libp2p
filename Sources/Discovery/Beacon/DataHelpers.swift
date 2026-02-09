import Foundation

// MARK: - Data Helpers for Big-Endian Integer Reading

extension Data {
    /// Reads a big-endian UInt16 from the given offset.
    func loadBigEndianUInt16(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[offset]) << 8
        let b1 = UInt16(self[offset + 1])
        return b0 | b1
    }

    /// Reads a big-endian UInt32 from the given offset.
    func loadBigEndianUInt32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset]) << 24
        let b1 = UInt32(self[offset + 1]) << 16
        let b2 = UInt32(self[offset + 2]) << 8
        let b3 = UInt32(self[offset + 3])
        return b0 | b1 | b2 | b3
    }

    /// Reads a big-endian UInt64 from the given offset.
    func loadBigEndianUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(self[offset + i])
        }
        return value
    }
}
