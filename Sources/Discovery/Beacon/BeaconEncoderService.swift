import Foundation
import Crypto
import P2PCore

/// Encoding errors.
public enum BeaconEncodingError: Error, Sendable {
    /// The maximum beacon size is too small for any tier.
    case payloadTooSmall(maxSize: Int, minimumRequired: Int)

    /// The peer record is too large to fit in the available space.
    case recordTooLarge(recordSize: Int, available: Int)

    /// Failed to create a signed peer record.
    case recordCreationFailed(underlying: any Error)
}

/// Facade for beacon encoding and decoding.
///
/// Selects the appropriate tier based on available payload size and
/// provides methods to encode and decode beacon payloads.
public struct BeaconEncoderService: Sendable {

    public init() {}

    // MARK: - Tier Selection

    /// Selects the highest tier that fits within the given beacon size.
    ///
    /// - Parameter maxBeaconSize: Maximum payload size in bytes.
    /// - Returns: The highest tier that fits, or `nil` if nothing fits.
    public func selectTier(maxBeaconSize: Int) -> BeaconTier? {
        // Try highest tier first, fall back to lower tiers
        if maxBeaconSize >= BeaconTier.tier3.minimumSize {
            return .tier3
        } else if maxBeaconSize >= BeaconTier.tier2.minimumSize {
            return .tier2
        } else if maxBeaconSize >= BeaconTier.tier1.minimumSize {
            return .tier1
        }
        return nil
    }

    // MARK: - Encoding

    /// Encodes a Tier 1 beacon.
    ///
    /// - Parameters:
    ///   - truncID: 2-byte truncated peer ID.
    ///   - nonce: 4-byte nonce.
    ///   - difficulty: PoW difficulty (default 16 bits).
    /// - Returns: 10-byte encoded beacon payload.
    public func encodeTier1(
        truncID: UInt16,
        nonce: UInt32,
        difficulty: Int = MicroPoW.defaultDifficulty
    ) -> Data {
        let pow = MicroPoW.solve(truncID: truncID, nonce: nonce, difficulty: difficulty)
        let beacon = Tier1Beacon(truncID: truncID, pow: pow, nonce: nonce)
        return beacon.encode()
    }

    /// Encodes a Tier 2 beacon.
    ///
    /// - Parameters:
    ///   - truncID: 2-byte truncated peer ID.
    ///   - nonce: 4-byte nonce.
    ///   - tesla: Micro-TESLA instance for MAC and key disclosure.
    ///   - capBloom: 10-byte capability bloom filter.
    ///   - difficulty: PoW difficulty (default 16 bits).
    /// - Returns: 32-byte encoded beacon payload.
    public func encodeTier2(
        truncID: UInt16,
        nonce: UInt32,
        tesla: MicroTESLA,
        capBloom: Data,
        difficulty: Int = MicroPoW.defaultDifficulty
    ) -> Data {
        let pow = MicroPoW.solve(truncID: truncID, nonce: nonce, difficulty: difficulty)

        // Build the data to MAC: truncID + PoW + nonce (all beacon fields)
        var macInput = Data(capacity: 9)
        withUnsafeBytes(of: truncID.bigEndian) { macInput.append(contentsOf: $0) }
        macInput.append(pow.0)
        macInput.append(pow.1)
        macInput.append(pow.2)
        withUnsafeBytes(of: nonce.bigEndian) { macInput.append(contentsOf: $0) }
        let macT = tesla.macForCurrentEpoch(data: macInput)
        let keyP = tesla.previousKey()

        let bloomData: Data
        if capBloom.count >= 10 {
            bloomData = capBloom.prefix(10)
        } else {
            var padded = capBloom
            padded.append(Data(repeating: 0, count: 10 - capBloom.count))
            bloomData = padded
        }

        let beacon = Tier2Beacon(
            truncID: truncID,
            pow: pow,
            nonce: nonce,
            macT: macT,
            keyP: keyP,
            capBloom: bloomData
        )
        return beacon.encode()
    }

    /// Encodes a Tier 3 beacon.
    ///
    /// - Parameters:
    ///   - keyPair: The local key pair for signing.
    ///   - nonce: 4-byte nonce.
    ///   - addresses: Opaque addresses to include in the signed peer record.
    ///   - sequenceNumber: Monotonically increasing sequence number.
    /// - Returns: Variable-length encoded beacon payload.
    /// - Throws: `BeaconEncodingError.recordCreationFailed` if signing fails.
    public func encodeTier3(
        keyPair: KeyPair,
        nonce: UInt32,
        addresses: [OpaqueAddress] = [],
        sequenceNumber: UInt64 = 0
    ) throws -> Data {
        let peerID = keyPair.peerID
        let record = BeaconPeerRecord(
            peerID: peerID,
            seq: sequenceNumber,
            opaqueAddresses: addresses
        )

        let envelope: Envelope
        do {
            envelope = try Envelope.seal(record: record, with: keyPair)
        } catch {
            throw BeaconEncodingError.recordCreationFailed(underlying: error)
        }

        let beacon = Tier3Beacon(
            peerID: peerID,
            nonce: nonce,
            envelope: envelope
        )

        do {
            return try beacon.encode()
        } catch {
            throw BeaconEncodingError.recordCreationFailed(underlying: error)
        }
    }

    // MARK: - Decoding

    /// Decodes a raw beacon payload into a `DecodedBeacon`.
    ///
    /// - Parameter payload: Raw beacon bytes (must start with a valid tag byte).
    /// - Returns: A decoded beacon, or `nil` if the payload is malformed.
    public func decode(payload: Data) -> DecodedBeacon? {
        guard let firstByte = payload.first else { return nil }
        guard let tier = BeaconTier(tagByte: firstByte) else { return nil }

        switch tier {
        case .tier1:
            return decodeTier1(payload: payload)
        case .tier2:
            return decodeTier2(payload: payload)
        case .tier3:
            return decodeTier3(payload: payload)
        }
    }

    // MARK: - Private Decode Helpers

    private func decodeTier1(payload: Data) -> DecodedBeacon? {
        guard let beacon = Tier1Beacon.decode(from: payload) else { return nil }

        var nonceData = Data(capacity: 4)
        withUnsafeBytes(of: beacon.nonce.bigEndian) { nonceData.append(contentsOf: $0) }

        return DecodedBeacon(
            tier: .tier1,
            truncID: beacon.truncID,
            nonce: nonceData,
            powValid: beacon.isValid()
        )
    }

    private func decodeTier2(payload: Data) -> DecodedBeacon? {
        guard let beacon = Tier2Beacon.decode(from: payload) else { return nil }

        var nonceData = Data(capacity: 4)
        withUnsafeBytes(of: beacon.nonce.bigEndian) { nonceData.append(contentsOf: $0) }

        return DecodedBeacon(
            tier: .tier2,
            truncID: beacon.truncID,
            nonce: nonceData,
            powValid: beacon.isValid(),
            teslaMAC: beacon.macT,
            teslaPrevKey: beacon.keyP,
            capabilityBloom: beacon.capBloom
        )
    }

    private func decodeTier3(payload: Data) -> DecodedBeacon? {
        guard let beacon = Tier3Beacon.decode(from: payload) else { return nil }

        var nonceData = Data(capacity: 4)
        withUnsafeBytes(of: beacon.nonce.bigEndian) { nonceData.append(contentsOf: $0) }

        do {
            let peerID = try PeerID(bytes: beacon.peerIDBytes)
            return DecodedBeacon(
                tier: .tier3,
                fullID: peerID,
                nonce: nonceData,
                powValid: true, // Tier 3 has no PoW
                envelope: beacon.envelope
            )
        } catch {
            return nil
        }
    }
}
