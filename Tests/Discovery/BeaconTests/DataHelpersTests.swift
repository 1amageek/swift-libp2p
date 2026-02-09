import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("DataHelpers")
struct DataHelpersTests {

    @Test("loadBigEndianUInt16")
    func loadBigEndianUInt16() {
        let data = Data([0x01, 0x02])
        let value = data.loadBigEndianUInt16(at: 0)
        #expect(value == 258) // 0x0102
    }

    @Test("loadBigEndianUInt32")
    func loadBigEndianUInt32() {
        let data = Data([0x00, 0x00, 0x01, 0x00])
        let value = data.loadBigEndianUInt32(at: 0)
        #expect(value == 256) // 0x00000100
    }

    @Test("loadBigEndianUInt64")
    func loadBigEndianUInt64() {
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        let value = data.loadBigEndianUInt64(at: 0)
        #expect(value == 1)
    }

    @Test("max values")
    func maxValues() {
        let data16 = Data([0xFF, 0xFF])
        #expect(data16.loadBigEndianUInt16(at: 0) == UInt16.max)

        let data32 = Data([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(data32.loadBigEndianUInt32(at: 0) == UInt32.max)

        let data64 = Data(repeating: 0xFF, count: 8)
        #expect(data64.loadBigEndianUInt64(at: 0) == UInt64.max)
    }
}
