/// IPNSRecordOverflowTests - Regression tests for the IPNS decode length-overflow
/// fix (review finding R1).
///
/// `IPNSRecord.decode` previously did `let len = Int(length)` on an
/// attacker-controlled length-prefix varint. For `length > Int.max` the
/// `Int(_:)` conversion TRAPS (crashes the process) — a remote-crash DoS. The
/// fix routes every length through the throwing `Varint.toInt`, so an oversized
/// length is rejected with a typed throw instead of trapping.
import Testing
import Foundation
@testable import P2PKademlia
@testable import P2PCore
import LibP2PCore

@Suite("IPNS Record Overflow Tests")
struct IPNSRecordOverflowTests {

    /// Appends an unsigned LEB128 varint for `value` to `bytes`.
    private func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    /// Builds an IPNS protobuf message where field 1 (`value`, wire type 2)
    /// declares a length-prefix varint of `declaredLength`. No actual value bytes
    /// follow — a real decoder must reject before allocating.
    private func makeRecordWithValueLength(_ declaredLength: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        // Field 1, wire type 2 (length-delimited): tag = (1 << 3) | 2 = 0x0A.
        bytes.append(0x0A)
        appendVarint(declaredLength, to: &bytes)
        return bytes
    }

    @Test("Decode rejects a value length-prefix exceeding Int.max (does not trap)")
    func valueLengthExceedingIntMaxThrows() {
        // UInt64.max > Int.max: the old `Int(length)` would trap here.
        let bytes = makeRecordWithValueLength(UInt64.max)
        #expect(throws: (any Error).self) {
            _ = try IPNSRecord.decode(from: bytes)
        }
    }

    @Test("Decode rejects an Int.max+1 length-prefix (boundary, does not trap)")
    func valueLengthIntMaxPlusOneThrows() {
        let overflow = UInt64(Int.max) + 1
        let bytes = makeRecordWithValueLength(overflow)
        #expect(throws: (any Error).self) {
            _ = try IPNSRecord.decode(from: bytes)
        }
    }

    @Test("Decode rejects an oversized length in the unknown-field skip path (does not trap)")
    func unknownFieldLengthExceedingIntMaxThrows() {
        // Field 15 (unknown), wire type 2: tag = (15 << 3) | 2 = 0x7A. The decode
        // skip-path for unknown length-delimited fields also routed `Int(length)`
        // through the unchecked conversion; assert it now throws.
        var bytes: [UInt8] = [0x7A]
        appendVarint(UInt64.max, to: &bytes)
        #expect(throws: (any Error).self) {
            _ = try IPNSRecord.decode(from: bytes)
        }
    }
}
