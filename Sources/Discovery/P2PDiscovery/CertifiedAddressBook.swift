/// P2PDiscovery - CertifiedAddressBook
///
/// Validates and stores signed PeerRecords (Envelopes).
/// Only accepts records with valid signatures and higher sequence numbers.

import Foundation
import P2PCore
import Synchronization

// MARK: - Events

/// Events emitted by the CertifiedAddressBook.
public enum CertifiedAddressBookEvent: Sendable {
    /// A signed peer record was accepted and stored.
    case recordAccepted(PeerID)
    /// A signed peer record was rejected.
    case recordRejected(PeerID, reason: String)
}

// MARK: - Errors

/// Errors that can occur when consuming peer records.
public enum CertifiedAddressBookError: Error, Sendable {
    /// The envelope signature is invalid.
    case invalidSignature
    /// The envelope payload type does not match PeerRecord.
    case payloadTypeMismatch
    /// The PeerID in the record does not match the envelope signer.
    case peerIDMismatch
    /// The record could not be extracted from the envelope.
    case recordExtractionFailed(any Error)
}

// MARK: - Protocol

/// Protocol for storing and validating signed peer address records.
///
/// CertifiedAddressBook validates signed Envelopes containing PeerRecords,
/// ensuring that only cryptographically verified addresses are stored.
/// Only records with higher sequence numbers replace existing ones.
public protocol CertifiedAddressBookProtocol: Sendable {

    /// Consumes and validates a signed PeerRecord envelope.
    ///
    /// - Parameter envelope: The signed envelope containing a PeerRecord.
    /// - Returns: `true` if the record was accepted (valid and newer).
    /// - Throws: `CertifiedAddressBookError` if the envelope is invalid.
    func consumePeerRecord(_ envelope: Envelope) throws -> Bool

    /// Returns the stored envelope for a peer, if any.
    func peerRecord(for peer: PeerID) -> Envelope?

    /// Returns certified addresses for a peer.
    func certifiedAddresses(for peer: PeerID) -> [Multiaddr]

    /// Returns all peers with certified records.
    func allCertifiedPeers() -> [PeerID]

    /// Event stream. Each call returns an independent subscriber stream.
    var events: AsyncStream<CertifiedAddressBookEvent> { get }

    /// Shuts down the address book and terminates all event streams.
    func shutdown()
}

// MARK: - Implementation

/// Default implementation of CertifiedAddressBook.
///
/// Uses `Mutex` for thread-safe high-frequency access (Discovery layer pattern).
/// Events are distributed via `EventBroadcaster` (multi-consumer).
public final class CertifiedAddressBook: CertifiedAddressBookProtocol, Sendable {

    // MARK: - State

    private let state: Mutex<State>
    private let broadcaster = EventBroadcaster<CertifiedAddressBookEvent>()

    private struct State: Sendable {
        var records: [PeerID: CertifiedRecord] = [:]
    }

    private struct CertifiedRecord: Sendable {
        let envelope: Envelope
        let peerRecord: P2PCore.PeerRecord
        let sequenceNumber: UInt64
    }

    // MARK: - Initialization

    /// Creates a new CertifiedAddressBook.
    public init() {
        self.state = Mutex(State())
    }

    deinit {
        broadcaster.shutdown()
    }

    // MARK: - CertifiedAddressBookProtocol

    public var events: AsyncStream<CertifiedAddressBookEvent> {
        broadcaster.subscribe()
    }

    public func consumePeerRecord(_ envelope: Envelope) throws -> Bool {
        // 1. Verify envelope signature and extract the PeerRecord
        let peerRecord: P2PCore.PeerRecord
        do {
            peerRecord = try envelope.record(as: P2PCore.PeerRecord.self)
        } catch let error as EnvelopeError {
            switch error {
            case .invalidSignature:
                throw CertifiedAddressBookError.invalidSignature
            case .payloadTypeMismatch:
                throw CertifiedAddressBookError.payloadTypeMismatch
            default:
                throw CertifiedAddressBookError.recordExtractionFailed(error)
            }
        } catch {
            throw CertifiedAddressBookError.recordExtractionFailed(error)
        }

        // 2. Verify that the PeerID in the record matches the envelope signer
        let signerPeerID = envelope.peerID
        guard peerRecord.peerID == signerPeerID else {
            throw CertifiedAddressBookError.peerIDMismatch
        }

        // 3. Check sequence number and store if newer (collect events outside lock)
        let pendingEvent: CertifiedAddressBookEvent = state.withLock { s in
            if let existing = s.records[signerPeerID] {
                if peerRecord.seq <= existing.sequenceNumber {
                    return .recordRejected(
                        signerPeerID,
                        reason: "Sequence number \(peerRecord.seq) is not newer than stored \(existing.sequenceNumber)"
                    )
                }
            }

            s.records[signerPeerID] = CertifiedRecord(
                envelope: envelope,
                peerRecord: peerRecord,
                sequenceNumber: peerRecord.seq
            )
            return .recordAccepted(signerPeerID)
        }

        // 4. Emit event outside lock
        broadcaster.emit(pendingEvent)

        // 5. Return whether the record was accepted
        switch pendingEvent {
        case .recordAccepted:
            return true
        case .recordRejected:
            return false
        }
    }

    public func peerRecord(for peer: PeerID) -> Envelope? {
        state.withLock { $0.records[peer]?.envelope }
    }

    public func certifiedAddresses(for peer: PeerID) -> [Multiaddr] {
        state.withLock { s in
            guard let record = s.records[peer] else { return [] }
            return record.peerRecord.addresses.map(\.multiaddr)
        }
    }

    public func allCertifiedPeers() -> [PeerID] {
        state.withLock { Array($0.records.keys) }
    }

    public func shutdown() {
        state.withLock { s in
            s.records.removeAll()
        }
        broadcaster.shutdown()
    }
}
