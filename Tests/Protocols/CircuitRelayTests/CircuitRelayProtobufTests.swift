/// Tests for Circuit Relay protobuf encoding/decoding.

import Testing
import Foundation
@testable import P2PCircuitRelay
@testable import P2PCore

@Suite("CircuitRelay Protobuf Tests")
struct CircuitRelayProtobufTests {

    // MARK: - HopMessage Tests

    @Test("Encode and decode RESERVE request")
    func encodeDecodeReserve() throws {
        let message = HopMessage.reserve()
        let encoded = CircuitRelayProtobuf.encode(message)
        let decoded = try CircuitRelayProtobuf.decodeHop(encoded)

        #expect(decoded.type == .reserve)
        #expect(decoded.peer == nil)
        #expect(decoded.reservation == nil)
        #expect(decoded.status == nil)
    }

    @Test("Encode and decode CONNECT request")
    func encodeDecodeConnect() throws {
        let keyPair = KeyPair.generateEd25519()
        let targetPeer = keyPair.peerID

        let message = HopMessage.connect(to: targetPeer)
        let encoded = CircuitRelayProtobuf.encode(message)
        let decoded = try CircuitRelayProtobuf.decodeHop(encoded)

        #expect(decoded.type == .connect)
        #expect(decoded.peer?.id == targetPeer)
    }

    @Test("Encode and decode STATUS response with reservation")
    func encodeDecodeStatusWithReservation() throws {
        let expiration: UInt64 = 1234567890
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        ]
        let resInfo = ReservationInfo(
            expiration: expiration,
            addresses: addresses,
            voucher: Data([0x01, 0x02, 0x03])
        )
        let limit = CircuitLimit(duration: .seconds(120), data: 131072)

        let message = HopMessage.statusResponse(.ok, reservation: resInfo, limit: limit)
        let encoded = CircuitRelayProtobuf.encode(message)
        let decoded = try CircuitRelayProtobuf.decodeHop(encoded)

        #expect(decoded.type == .status)
        #expect(decoded.status == .ok)
        #expect(decoded.reservation?.expiration == expiration)
        #expect(decoded.reservation?.addresses.count == 1)
        #expect(decoded.reservation?.voucher == Data([0x01, 0x02, 0x03]))
        #expect(decoded.limit?.duration == .seconds(120))
        #expect(decoded.limit?.data == 131072)
    }

    @Test("Encode and decode error status")
    func encodeDecodeErrorStatus() throws {
        let message = HopMessage.statusResponse(.resourceLimitExceeded)
        let encoded = CircuitRelayProtobuf.encode(message)
        let decoded = try CircuitRelayProtobuf.decodeHop(encoded)

        #expect(decoded.type == .status)
        #expect(decoded.status == .resourceLimitExceeded)
    }

    // MARK: - StopMessage Tests

    @Test("Encode and decode STOP CONNECT")
    func encodeDecodeStopConnect() throws {
        let keyPair = KeyPair.generateEd25519()
        let sourcePeer = keyPair.peerID
        let limit = CircuitLimit(duration: .seconds(60), data: 65536)

        let message = StopMessage.connect(from: sourcePeer, limit: limit)
        let encoded = CircuitRelayProtobuf.encode(message)
        let decoded = try CircuitRelayProtobuf.decodeStop(encoded)

        #expect(decoded.type == .connect)
        #expect(decoded.peer?.id == sourcePeer)
        #expect(decoded.limit?.duration == .seconds(60))
        #expect(decoded.limit?.data == 65536)
    }

    @Test("Encode and decode STOP STATUS")
    func encodeDecodeStopStatus() throws {
        let message = StopMessage.statusResponse(.ok)
        let encoded = CircuitRelayProtobuf.encode(message)
        let decoded = try CircuitRelayProtobuf.decodeStop(encoded)

        #expect(decoded.type == .status)
        #expect(decoded.status == .ok)
    }

    // MARK: - Limit Tests

    @Test("Encode and decode limit with both fields")
    func encodeLimitBothFields() throws {
        let limit = CircuitLimit(duration: .seconds(300), data: 1048576)
        let message = HopMessage.statusResponse(.ok, limit: limit)
        let encoded = CircuitRelayProtobuf.encode(message)
        let decoded = try CircuitRelayProtobuf.decodeHop(encoded)

        #expect(decoded.limit?.duration == .seconds(300))
        #expect(decoded.limit?.data == 1048576)
    }

    @Test("Encode and decode limit with only duration")
    func encodeLimitDurationOnly() throws {
        let limit = CircuitLimit(duration: .seconds(60), data: nil)
        let message = HopMessage.statusResponse(.ok, limit: limit)
        let encoded = CircuitRelayProtobuf.encode(message)
        let decoded = try CircuitRelayProtobuf.decodeHop(encoded)

        #expect(decoded.limit?.duration == .seconds(60))
        #expect(decoded.limit?.data == nil)
    }

    @Test("Encode and decode limit with only data")
    func encodeLimitDataOnly() throws {
        let limit = CircuitLimit(duration: nil, data: 32768)
        let message = HopMessage.statusResponse(.ok, limit: limit)
        let encoded = CircuitRelayProtobuf.encode(message)
        let decoded = try CircuitRelayProtobuf.decodeHop(encoded)

        #expect(decoded.limit?.duration == nil)
        #expect(decoded.limit?.data == 32768)
    }
}
