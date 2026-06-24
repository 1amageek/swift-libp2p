/// CodecCapTests - Regression tests for the per-element / per-byte caps added to
/// the protocol codecs (review finding R2, HIGH-cluster memory DoS).
///
/// Several length-delimited protobuf codecs in `LibP2PCore` appended to repeated
/// fields without an inner per-element cap, so a single crafted message could
/// force unbounded allocation. The fixes add per-repeated-field count caps
/// (mirroring GossipSub's existing `if arr.count < max { append }` pattern) and
/// per-value byte caps. These tests feed an oversized field and assert the result
/// is BOUNDED (capped) or REJECTED (typed throw) — never unbounded.
import Testing
import Foundation
import LibP2PCore

@Suite("Codec Cap Tests")
struct CodecCapTests {

    // MARK: - Protobuf wire builders

    private func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    /// Appends a length-delimited (wire type 2) field: tag, length, payload.
    private func appendLengthDelimited(field: UInt64, payload: [UInt8], to bytes: inout [UInt8]) {
        appendVarint((field << 3) | 2, to: &bytes)
        appendVarint(UInt64(payload.count), to: &bytes)
        bytes.append(contentsOf: payload)
    }

    /// Wraps `payload` as a length-delimited field with the given field number.
    private func lengthDelimited(field: UInt64, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        appendLengthDelimited(field: field, payload: payload, to: &bytes)
        return bytes
    }

    // MARK: - Identify: listenAddrs / protocols caps

    @Test("Identify listenAddrs is bounded under a flood of repeated entries")
    func identifyListenAddrsBounded() throws {
        // Field 2 (listenAddrs) repeated many times beyond the cap.
        var bytes: [UInt8] = []
        let flood = 5_000
        for _ in 0..<flood {
            appendLengthDelimited(field: 2, payload: [0x01, 0x02, 0x03], to: &bytes)
        }
        let cap = 100
        let fields = try IdentifyFields.decode(from: bytes, maxListenAddrs: cap, maxProtocols: cap)
        // Bounded: the decoder caps the repeated field rather than allocating all.
        #expect(fields.listenAddrs.count <= cap)
    }

    @Test("Identify protocols is bounded under a flood of repeated entries")
    func identifyProtocolsBounded() throws {
        // Field 3 (protocols) repeated many times beyond the cap. Use valid UTF-8.
        var bytes: [UInt8] = []
        let flood = 5_000
        for _ in 0..<flood {
            appendLengthDelimited(field: 3, payload: Array("/p/1.0.0".utf8), to: &bytes)
        }
        let cap = 50
        let fields = try IdentifyFields.decode(from: bytes, maxListenAddrs: 1000, maxProtocols: cap)
        #expect(fields.protocols.count <= cap)
    }

    // MARK: - GossipSub: inner messageIDs cap (IHAVE)

    @Test("GossipSub IHAVE inner messageIDs is bounded")
    func gossipSubIHaveMessageIDsBounded() throws {
        // Build an IHAVE: field 1 = topic (string), field 2 = messageID (repeated).
        var ihave: [UInt8] = []
        appendLengthDelimited(field: 1, payload: Array("topic".utf8), to: &ihave)
        let flood = 5_000
        for _ in 0..<flood {
            appendLengthDelimited(field: 2, payload: [0xAA, 0xBB], to: &ihave)
        }
        // Control: field 1 = IHAVE entry.
        let control = lengthDelimited(field: 1, payload: ihave)
        // RPC: field 3 = control.
        let rpc = lengthDelimited(field: 3, payload: control)

        let limits = GossipSubDecodingLimits(maxMessageIDsPerControl: 100)
        let fields = try GossipSubRPCFields.decode(from: rpc, limits: limits)
        let ihaves = fields.control?.ihaves ?? []
        #expect(ihaves.count == 1)
        #expect((ihaves.first?.messageIDs.count ?? .max) <= 100)
    }

    // MARK: - Kademlia: Record.value byte cap (rejects)

    @Test("Kademlia decode rejects an oversized record value")
    func kademliaRecordValueByteCapRejects() {
        // Record: field 2 = value (bytes). Build a Record larger than the cap, wrap
        // it as RPC field 3 (record).
        let bigValue = [UInt8](repeating: 0xCD, count: 2_000)
        let record = lengthDelimited(field: 2, payload: bigValue)
        let rpc = lengthDelimited(field: 3, payload: record)

        #expect(throws: KademliaCodecError.self) {
            _ = try KademliaFields.decode(from: rpc, maxPeers: 100, maxRecordValueBytes: 1_000)
        }
    }

    @Test("Kademlia decode accepts a record value within the byte cap")
    func kademliaRecordValueWithinCapAccepted() throws {
        let okValue = [UInt8](repeating: 0xCD, count: 500)
        let key = lengthDelimited(field: 1, payload: Array("k".utf8))
        var recordBody = key
        appendLengthDelimited(field: 2, payload: okValue, to: &recordBody)
        let rpc = lengthDelimited(field: 3, payload: recordBody)

        let fields = try KademliaFields.decode(from: rpc, maxPeers: 100, maxRecordValueBytes: 1_000)
        #expect(fields.record?.value.count == 500)
    }

    // MARK: - Plumtree: Gossip.data byte cap (rejects)

    @Test("Plumtree decode rejects an oversized gossip data payload")
    func plumtreeGossipDataByteCapRejects() {
        // Gossip: field 1 = messageID, field 2 = topic, field 3 = data (oversized),
        // field 4 = source. RPC field 1 = gossip.
        var gossip: [UInt8] = []
        appendLengthDelimited(field: 1, payload: [0x01], to: &gossip)
        appendLengthDelimited(field: 2, payload: Array("topic".utf8), to: &gossip)
        appendLengthDelimited(
            field: 3,
            payload: [UInt8](repeating: 0xEE, count: PlumtreeRPCFields.maxGossipDataBytes + 1),
            to: &gossip
        )
        appendLengthDelimited(field: 4, payload: [0x02], to: &gossip)
        let rpc = lengthDelimited(field: 1, payload: gossip)

        #expect(throws: PlumtreeCodecError.self) {
            _ = try PlumtreeRPCFields.decode(from: rpc)
        }
    }
}
