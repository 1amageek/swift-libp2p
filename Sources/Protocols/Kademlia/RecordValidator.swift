/// RecordValidator - Protocol for validating Kademlia DHT records.
///
/// Validators allow applications to define custom rules for accepting or rejecting
/// records stored in the DHT. This is essential for security, as the DHT is a
/// public data structure where any node can attempt to store arbitrary data.

import Foundation
import P2PCore

/// Protocol for validating Kademlia DHT records.
///
/// Implement this protocol to define custom validation rules for records.
/// For example, you might require records to be signed, match a specific schema,
/// or come from authorized peers.
///
/// ## Example
///
/// ```swift
/// struct MyValidator: RecordValidator {
///     func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
///         // Check that the record has valid signature
///         guard let signature = parseSignature(from: record.value) else {
///             return false
///         }
///         return verifySignature(signature, for: record.key)
///     }
/// }
/// ```
public protocol RecordValidator: Sendable {
    /// Validates a record.
    ///
    /// - Parameters:
    ///   - record: The record to validate.
    ///   - from: The peer ID that sent the record.
    /// - Returns: `true` if the record is valid and should be stored, `false` otherwise.
    /// - Throws: Any error during validation (will be treated as validation failure).
    func validate(record: KademliaRecord, from: PeerID) async throws -> Bool

    /// Selects the best record from multiple records for the same key.
    ///
    /// When a GET_VALUE query receives records from multiple peers, this method
    /// determines which record is the "best" one to return. This corresponds to
    /// Go's `Select(key string, vals [][]byte) (int, error)`.
    ///
    /// - Parameters:
    ///   - key: The record key.
    ///   - records: The candidate records (non-empty).
    /// - Returns: The index (0-based) of the best record.
    /// - Throws: `RecordSelectionError` if no valid selection can be made.
    func select(key: Data, records: [KademliaRecord]) async throws -> Int
}

// MARK: - Default select implementation

extension RecordValidator {
    /// Default implementation: selects the first record (backward compatible).
    public func select(key: Data, records: [KademliaRecord]) async throws -> Int {
        guard !records.isEmpty else {
            throw RecordSelectionError.noRecords
        }
        return 0
    }
}

/// Errors from record selection.
public enum RecordSelectionError: Error, Sendable {
    /// No records were provided.
    case noRecords
    /// All candidate records were invalid.
    case allRecordsInvalid
}

/// Reasons for rejecting a record.
public enum RecordRejectionReason: Sendable, Equatable {
    /// Record failed validation by the validator.
    case validationFailed

    /// Validation threw an error.
    case validationError(String)

    /// Record signature is invalid.
    case invalidSignature

    /// Record signer doesn't match expected key owner.
    case signerMismatch

    /// Namespace is not recognized.
    case unknownNamespace(String)
}

// MARK: - Built-in Validators

/// A validator that accepts all records (no validation).
///
/// This is the default validator when none is specified, maintaining
/// backward compatibility with existing code.
public struct AcceptAllValidator: RecordValidator {
    public init() {}

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        true
    }
}

/// A validator that rejects all records.
///
/// Useful for testing or for nodes that should only serve as routers
/// without storing any data.
public struct RejectAllValidator: RecordValidator {
    public init() {}

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        false
    }
}

/// A validator that dispatches to namespace-specific validators.
///
/// Records are routed to validators based on their key namespace prefix.
/// For example, keys starting with `/pk/` go to the public key validator,
/// keys starting with `/ipns/` go to the IPNS validator, etc.
///
/// ## Example
///
/// ```swift
/// let validator = NamespacedValidator(
///     validators: [
///         "/pk/": PublicKeyValidator(),
///         "/ipns/": IPNSValidator()
///     ],
///     defaultBehavior: .reject
/// )
/// ```
public final class NamespacedValidator: RecordValidator, Sendable {
    /// Namespace to validator mapping.
    private let validators: [String: any RecordValidator]

    /// Behavior for unknown namespaces.
    public let defaultBehavior: DefaultBehavior

    /// Behavior when namespace is not recognized.
    public enum DefaultBehavior: Sendable {
        /// Accept records from unknown namespaces.
        case accept

        /// Reject records from unknown namespaces.
        case reject
    }

    /// Creates a namespaced validator.
    ///
    /// - Parameters:
    ///   - validators: A mapping of namespace prefixes to their validators.
    ///   - defaultBehavior: Behavior for records with unrecognized namespaces.
    public init(
        validators: [String: any RecordValidator],
        defaultBehavior: DefaultBehavior = .reject
    ) {
        self.validators = validators
        self.defaultBehavior = defaultBehavior
    }

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        let namespace = extractNamespace(from: record.key)

        guard let validator = validators[namespace] else {
            // Unknown namespace
            return defaultBehavior == .accept
        }

        return try await validator.validate(record: record, from: from)
    }

    public func select(key: Data, records: [KademliaRecord]) async throws -> Int {
        guard !records.isEmpty else {
            throw RecordSelectionError.noRecords
        }

        let namespace = extractNamespace(from: key)

        guard let validator = validators[namespace] else {
            // Unknown namespace — default to first record
            return 0
        }

        return try await validator.select(key: key, records: records)
    }

    /// Extracts the namespace prefix from a key.
    ///
    /// For example:
    /// - `/pk/Qm...` returns `/pk/`
    /// - `/ipns/Qm...` returns `/ipns/`
    /// - `random-key` returns empty string
    private func extractNamespace(from key: Data) -> String {
        // Try to interpret key as UTF-8 string
        guard let keyString = String(data: key, encoding: .utf8) else {
            return ""
        }

        // Look for namespace pattern: /namespace/...
        guard keyString.hasPrefix("/") else {
            return ""
        }

        // Find the second slash
        let afterFirst = keyString.dropFirst()
        guard let secondSlashIndex = afterFirst.firstIndex(of: "/") else {
            return ""
        }

        // Return the namespace including both slashes
        let endIndex = afterFirst.index(after: secondSlashIndex)
        return String(keyString[..<keyString.index(keyString.startIndex, offsetBy: afterFirst.distance(from: afterFirst.startIndex, to: endIndex) + 1)])
    }
}

/// A validator that checks key length requirements.
///
/// Useful for ensuring keys meet minimum/maximum length constraints.
public struct KeyLengthValidator: RecordValidator {
    /// Minimum key length (in bytes).
    public let minLength: Int?

    /// Maximum key length (in bytes).
    public let maxLength: Int?

    /// Creates a key length validator.
    ///
    /// - Parameters:
    ///   - minLength: Minimum key length (nil = no minimum).
    ///   - maxLength: Maximum key length (nil = no maximum).
    public init(minLength: Int? = nil, maxLength: Int? = nil) {
        self.minLength = minLength
        self.maxLength = maxLength
    }

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        let keyLength = record.key.count

        if let min = minLength, keyLength < min {
            return false
        }

        if let max = maxLength, keyLength > max {
            return false
        }

        return true
    }
}

/// A validator that checks value size requirements.
///
/// Useful for limiting the size of stored values to prevent abuse.
public struct ValueSizeValidator: RecordValidator {
    /// Maximum value size (in bytes).
    public let maxSize: Int

    /// Creates a value size validator.
    ///
    /// - Parameter maxSize: Maximum value size in bytes.
    public init(maxSize: Int) {
        self.maxSize = maxSize
    }

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        record.value.count <= maxSize
    }
}

/// A validator that combines multiple validators with AND logic.
///
/// All validators must pass for the record to be accepted.
public struct CompositeValidator: RecordValidator {
    /// The validators to combine.
    private let validators: [any RecordValidator]

    /// Creates a composite validator.
    ///
    /// - Parameter validators: The validators to combine (all must pass).
    public init(validators: [any RecordValidator]) {
        self.validators = validators
    }

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        for validator in validators {
            guard try await validator.validate(record: record, from: from) else {
                return false
            }
        }
        return true
    }
}

// MARK: - Default Validator

/// Default record validator with basic size limits.
///
/// This validator provides basic DoS protection by limiting key and value sizes.
/// It is used as the default validator when none is specified.
///
/// Default limits:
/// - Key size: 1KB (1024 bytes)
/// - Value size: 64KB (65536 bytes)
public struct DefaultRecordValidator: RecordValidator {
    /// Maximum key size in bytes.
    public let maxKeySize: Int

    /// Maximum value size in bytes.
    public let maxValueSize: Int

    /// Creates a default validator with size limits.
    ///
    /// - Parameters:
    ///   - maxKeySize: Maximum key size in bytes. Default: 1024 (1KB).
    ///   - maxValueSize: Maximum value size in bytes. Default: 65536 (64KB).
    public init(maxKeySize: Int = 1024, maxValueSize: Int = 65536) {
        self.maxKeySize = maxKeySize
        self.maxValueSize = maxValueSize
    }

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        record.key.count <= maxKeySize && record.value.count <= maxValueSize
    }
}

// MARK: - Signed Record Validators

/// A validator that verifies cryptographic signatures on records.
///
/// This validator parses the record's value as a libp2p Envelope and verifies
/// the signature using domain separation. Optionally, it can also verify that
/// the signer's PeerID matches an expected value extracted from the key.
///
/// ## Usage
///
/// ```swift
/// // Basic signature verification
/// let validator = SignedRecordValidator(domain: "libp2p-routing-record")
///
/// // With key-to-signer matching
/// let validator = SignedRecordValidator(
///     domain: "libp2p-routing-record",
///     requireKeyMatch: true,
///     extractExpectedPeerID: { key in
///         // Extract PeerID from key like "/pk/QmXYZ..."
///         guard let keyString = String(data: key, encoding: .utf8),
///               keyString.hasPrefix("/pk/") else { return nil }
///         do {
///             return try PeerID(string: String(keyString.dropFirst(4)))
///         } catch {
///             return nil
///         }
///     }
/// )
/// ```
public struct SignedRecordValidator: RecordValidator {
    /// Domain string for signature verification.
    public let domain: String

    /// Whether to require the signer's PeerID to match the expected value from the key.
    public let requireKeyMatch: Bool

    /// Function to extract the expected PeerID from a record key.
    /// Returns nil if the key format is not recognized.
    public let extractExpectedPeerID: (@Sendable (Data) -> PeerID?)?

    /// Creates a signed record validator.
    ///
    /// - Parameters:
    ///   - domain: Domain string for signature verification (e.g., "libp2p-routing-record").
    ///   - requireKeyMatch: If true, verifies that signer matches expected PeerID from key.
    ///   - extractExpectedPeerID: Function to extract expected PeerID from key (required if requireKeyMatch is true).
    public init(
        domain: String,
        requireKeyMatch: Bool = false,
        extractExpectedPeerID: (@Sendable (Data) -> PeerID?)? = nil
    ) {
        self.domain = domain
        self.requireKeyMatch = requireKeyMatch
        self.extractExpectedPeerID = extractExpectedPeerID
    }

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        // 1. Parse record.value as Envelope
        let envelope: Envelope
        do {
            envelope = try Envelope.unmarshal(record.value)
        } catch {
            return false
        }

        // 2. Verify signature with domain
        do {
            guard try envelope.verify(domain: domain) else {
                return false
            }
        } catch {
            return false
        }

        // 3. Optionally verify key-to-signer match
        if requireKeyMatch {
            guard let extract = extractExpectedPeerID,
                  let expectedPeerID = extract(record.key),
                  envelope.peerID == expectedPeerID else {
                return false
            }
        }

        return true
    }
}

/// A validator for `/pk/` namespace public key records.
///
/// This validator ensures that:
/// 1. The key starts with `/pk/` followed by a PeerID
/// 2. The value is a valid signed Envelope
/// 3. The signer's PeerID matches the PeerID in the key
///
/// This prevents unauthorized parties from publishing fake public keys
/// for other peers.
public struct PublicKeyValidator: RecordValidator {
    /// The namespace prefix for public key records.
    public static let namespace = "/pk/"

    /// The domain string for public key record signatures.
    public static let domain = "libp2p-routing-record"

    /// Creates a public key validator.
    public init() {}

    public func validate(record: KademliaRecord, from: PeerID) async throws -> Bool {
        // 1. Verify key is in /pk/{PeerID} format
        guard let keyString = String(data: record.key, encoding: .utf8),
              keyString.hasPrefix(Self.namespace) else {
            return false
        }

        // 2. Extract expected PeerID from key
        let peerIDPart = String(keyString.dropFirst(Self.namespace.count))
        let expectedPeerID: PeerID
        do {
            expectedPeerID = try PeerID(string: peerIDPart)
        } catch {
            return false
        }

        // 3. Parse and verify envelope
        let envelope: Envelope
        do {
            envelope = try Envelope.unmarshal(record.value)
        } catch {
            return false
        }

        do {
            guard try envelope.verify(domain: Self.domain) else {
                return false
            }
        } catch {
            return false
        }

        // 4. Verify signer matches key's PeerID
        guard envelope.peerID == expectedPeerID else {
            return false
        }

        return true
    }
}
