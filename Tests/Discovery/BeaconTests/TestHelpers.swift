import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

// MARK: - Shared Test Helpers

func makeKeyPair() -> KeyPair {
    KeyPair.generateEd25519()
}

func makePeerID() -> PeerID {
    makeKeyPair().peerID
}

func makeOpaqueAddress(medium: String = "ble") -> OpaqueAddress {
    OpaqueAddress(mediumID: medium, raw: Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
}

func makeEnvelope(keyPair: KeyPair, seq: UInt64 = 0, addresses: [OpaqueAddress] = []) throws -> Envelope {
    let record = BeaconPeerRecord(
        peerID: keyPair.peerID,
        seq: seq,
        opaqueAddresses: addresses
    )
    return try Envelope.seal(record: record, with: keyPair)
}

func makeBeaconObservation(
    medium: String = "ble",
    rssi: Double? = nil,
    timestamp: ContinuousClock.Instant = .now
) -> BeaconObservation {
    BeaconObservation(
        timestamp: timestamp,
        mediumID: medium,
        rssi: rssi,
        address: makeOpaqueAddress(medium: medium),
        freshnessFunction: freshnessForMedium(medium)
    )
}

func makeRawDiscovery(
    payload: Data,
    medium: String = "ble",
    rssi: Double? = nil,
    fingerprint: PhysicalFingerprint? = nil
) -> RawDiscovery {
    RawDiscovery(
        payload: payload,
        sourceAddress: makeOpaqueAddress(medium: medium),
        timestamp: .now,
        rssi: rssi,
        mediumID: medium,
        physicalFingerprint: fingerprint
    )
}

func makeConfirmedPeerRecord(keyPair: KeyPair? = nil, epoch: UInt64 = 0) throws -> ConfirmedPeerRecord {
    let kp = keyPair ?? makeKeyPair()
    let envelope = try makeEnvelope(keyPair: kp)
    return ConfirmedPeerRecord(
        peerID: kp.peerID,
        certificate: envelope,
        epoch: epoch
    )
}

private func freshnessForMedium(_ medium: String) -> FreshnessFunction {
    switch medium {
    case "nfc": return .nfc
    case "ble": return .ble
    case "wifi-direct": return .wifiDirect
    case "lora": return .lora
    default: return .gossip
    }
}
