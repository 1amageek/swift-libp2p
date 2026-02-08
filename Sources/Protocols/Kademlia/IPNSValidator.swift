/// IPNSValidator - Validates IPNS records stored in the Kademlia DHT.
///
/// Only handles keys with the /ipns/ prefix. Validates signature, expiry,
/// and key-to-signer correspondence. Also provides record selection logic
/// for choosing the best among multiple records for the same key.

import Foundation
import P2PCore

/// Validates IPNS records stored in the Kademlia DHT.
/// Only handles keys with the /ipns/ prefix.
public struct IPNSValidator: RecordValidator, Sendable {
    /// The namespace prefix for IPNS records.
    public static let namespace = "/ipns/"

    public init() {}

    // MARK: - RecordValidator Conformance

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        // Only handle /ipns/ keys
        guard handles(key: Array(record.key)) else {
            return false
        }
        do {
            let result = try validateRecord(key: Array(record.key), value: Array(record.value))
            return result
        } catch {
            return false
        }
    }

    public func select(key: Data, records: [KademliaRecord]) async throws -> Int {
        guard !records.isEmpty else {
            throw RecordSelectionError.noRecords
        }
        let rawRecords = records.map { Array($0.value) }
        return try selectBest(key: Array(key), records: rawRecords)
    }

    // MARK: - Key Handling

    /// Check if this validator handles the given key.
    public func handles(key: [UInt8]) -> Bool {
        guard let keyString = String(data: Data(key), encoding: .utf8) else {
            return false
        }
        return keyString.hasPrefix(Self.namespace)
    }

    // MARK: - Validation

    /// Validate an IPNS record.
    /// Checks: signature, expiry, key matches the /ipns/<peerID> key.
    ///
    /// - Parameters:
    ///   - key: The DHT key (should start with /ipns/<peerID>).
    ///   - value: The encoded IPNS record bytes.
    /// - Returns: `true` if the record is valid.
    /// - Throws: `IPNSRecordError` on validation failure.
    public func validate(key: [UInt8], value: [UInt8]) throws -> Bool {
        try validateRecord(key: key, value: value)
    }

    // MARK: - Selection

    /// Select the best record among multiple for the same key.
    /// Selection order: higher sequence > later expiry > earlier in list.
    ///
    /// - Parameters:
    ///   - key: The DHT key.
    ///   - records: The candidate IPNS record byte arrays.
    /// - Returns: The index (0-based) of the best record.
    /// - Throws: `RecordSelectionError.allRecordsInvalid` if no record can be decoded.
    public func select(key: [UInt8], records: [[UInt8]]) throws -> Int {
        try selectBest(key: key, records: records)
    }

    // MARK: - Internal

    /// Core validation logic.
    private func validateRecord(key: [UInt8], value: [UInt8]) throws -> Bool {
        // 1. Decode the record
        let record = try IPNSRecord.decode(from: value)

        // 2. Check expiry
        if record.validity < Date() {
            throw IPNSRecordError.expired
        }

        // 3. Extract the PeerID from the key
        guard let keyString = String(data: Data(key), encoding: .utf8),
              keyString.hasPrefix(Self.namespace) else {
            throw IPNSRecordError.keyMismatch
        }
        let peerIDString = String(keyString.dropFirst(Self.namespace.count))
        let expectedPeerID: PeerID
        do {
            expectedPeerID = try PeerID(string: peerIDString)
        } catch {
            throw IPNSRecordError.keyMismatch
        }

        // 4. Resolve the signer's public key
        let signerPublicKey: PublicKey
        if let pkBytes = record.publicKey {
            do {
                signerPublicKey = try PublicKey(protobufEncoded: Data(pkBytes))
            } catch {
                throw IPNSRecordError.invalidPublicKey
            }
        } else {
            // Try to extract from the PeerID (identity multihash)
            do {
                guard let pk = try expectedPeerID.extractPublicKey() else {
                    throw IPNSRecordError.invalidPublicKey
                }
                signerPublicKey = pk
            } catch {
                throw IPNSRecordError.invalidPublicKey
            }
        }

        // 5. Verify that the public key matches the PeerID in the key
        let derivedPeerID = PeerID(publicKey: signerPublicKey)
        guard derivedPeerID == expectedPeerID else {
            throw IPNSRecordError.keyMismatch
        }

        // 6. Verify the signature
        let signable = IPNSRecord.dataForSigning(
            value: record.value,
            validityType: record.validityType,
            validity: record.validity
        )

        let isValid: Bool
        do {
            isValid = try signerPublicKey.verify(
                signature: Data(record.signature),
                for: signable
            )
        } catch {
            throw IPNSRecordError.invalidSignature
        }

        guard isValid else {
            throw IPNSRecordError.invalidSignature
        }

        return true
    }

    /// Core selection logic.
    private func selectBest(key: [UInt8], records: [[UInt8]]) throws -> Int {
        guard !records.isEmpty else {
            throw RecordSelectionError.noRecords
        }

        // Decode all records, tracking which ones are valid
        var decoded: [(index: Int, record: IPNSRecord)] = []
        for (index, recordData) in records.enumerated() {
            do {
                let record = try IPNSRecord.decode(from: recordData)
                decoded.append((index, record))
            } catch {
                // Skip invalid records
                continue
            }
        }

        guard !decoded.isEmpty else {
            throw RecordSelectionError.allRecordsInvalid
        }

        // Select best: higher sequence wins, then later validity, then earlier index
        var bestIndex = decoded[0].index
        var bestRecord = decoded[0].record

        for i in 1 ..< decoded.count {
            let candidate = decoded[i]
            if candidate.record.sequence > bestRecord.sequence {
                bestIndex = candidate.index
                bestRecord = candidate.record
            } else if candidate.record.sequence == bestRecord.sequence {
                if candidate.record.validity > bestRecord.validity {
                    bestIndex = candidate.index
                    bestRecord = candidate.record
                }
                // If both sequence and validity are equal, earlier index wins (no change)
            }
        }

        return bestIndex
    }
}
