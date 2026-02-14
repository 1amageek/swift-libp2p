/// Message - GossipSub pub/sub message
import Foundation
import P2PCore

/// A message in the GossipSub pub/sub system.
///
/// Messages are published to topics and delivered to all subscribers.
public struct GossipSubMessage: Sendable, Hashable {
    /// The message ID (computed from source + seqno or custom function).
    public let id: MessageID

    /// The source peer ID (optional, may be omitted for anonymity).
    public let source: PeerID?

    /// The message payload data.
    public let data: Data

    /// The sequence number (8 bytes, big-endian).
    public let sequenceNumber: Data

    /// The topic this message was published to.
    public let topic: Topic

    /// The message signature (optional).
    public let signature: Data?

    /// The public key of the signer (optional, if not inlined in PeerID).
    public let key: Data?

    /// Creates a new GossipSub message.
    ///
    /// - Parameters:
    ///   - id: The message ID
    ///   - source: The source peer ID (optional)
    ///   - data: The message payload
    ///   - sequenceNumber: The sequence number
    ///   - topic: The topic
    ///   - signature: The signature (optional)
    ///   - key: The public key (optional)
    public init(
        id: MessageID,
        source: PeerID?,
        data: Data,
        sequenceNumber: Data,
        topic: Topic,
        signature: Data? = nil,
        key: Data? = nil
    ) {
        self.id = id
        self.source = source
        self.data = data
        self.sequenceNumber = sequenceNumber
        self.topic = topic
        self.signature = signature
        self.key = key
    }

    /// Creates a new message with auto-generated ID.
    ///
    /// - Parameters:
    ///   - source: The source peer ID
    ///   - data: The message payload
    ///   - sequenceNumber: The sequence number
    ///   - topic: The topic
    ///   - signature: The signature (optional)
    ///   - key: The public key (optional)
    public init(
        source: PeerID?,
        data: Data,
        sequenceNumber: Data,
        topic: Topic,
        signature: Data? = nil,
        key: Data? = nil
    ) {
        self.id = MessageID.compute(source: source, sequenceNumber: sequenceNumber)
        self.source = source
        self.data = data
        self.sequenceNumber = sequenceNumber
        self.topic = topic
        self.signature = signature
        self.key = key
    }
}

// MARK: - Message Builder

extension GossipSubMessage {
    /// Builder for creating signed messages.
    public struct Builder {
        private var data: Data
        private var topic: Topic
        private var source: PeerID?
        private var sequenceNumber: Data?
        private var signature: Data?
        private var key: Data?

        /// Creates a new message builder.
        ///
        /// - Parameters:
        ///   - data: The message payload
        ///   - topic: The topic to publish to
        public init(data: Data, topic: Topic) {
            self.data = data
            self.topic = topic
        }

        /// Sets the source peer ID.
        public func source(_ peerID: PeerID) -> Builder {
            var copy = self
            copy.source = peerID
            return copy
        }

        /// Sets the sequence number.
        public func sequenceNumber(_ seqno: Data) -> Builder {
            var copy = self
            copy.sequenceNumber = seqno
            return copy
        }

        /// Sets an auto-generated sequence number.
        public func autoSequenceNumber() -> Builder {
            var copy = self
            // Generate 8-byte random sequence number
            var seqno = Data(count: 8)
            for i in 0..<8 {
                seqno[i] = UInt8.random(in: 0...255)
            }
            copy.sequenceNumber = seqno
            return copy
        }

        /// Signs the message with the given private key.
        ///
        /// Must be called after `source()` has been set.
        /// This generates the sequence number if not already set.
        ///
        /// - Parameter privateKey: The private key to sign with
        /// - Returns: A new builder with signature and key set
        /// - Throws: `GossipSubError.signingRequiresSource` if source is not set
        public func sign(with privateKey: PrivateKey) throws -> Builder {
            guard let source = source else {
                throw GossipSubError.signingRequiresSource
            }

            // Generate sequence number if not set
            let seqno = sequenceNumber ?? Self.generateSequenceNumber()

            // Build signing data
            let signingData = Self.buildSigningData(
                source: source,
                data: data,
                seqno: seqno,
                topic: topic
            )

            var copy = self
            copy.sequenceNumber = seqno
            copy.signature = try privateKey.sign(signingData)
            copy.key = privateKey.publicKey.protobufEncoded
            return copy
        }

        /// Generates an 8-byte random sequence number.
        private static func generateSequenceNumber() -> Data {
            var seqno = Data(count: 8)
            for i in 0..<8 {
                seqno[i] = UInt8.random(in: 0...255)
            }
            return seqno
        }

        /// Builds the signing data per libp2p pubsub spec.
        ///
        /// Format: "libp2p-pubsub:" + protobuf(from, data, seqno, topic)
        private static func buildSigningData(source: PeerID, data: Data, seqno: Data, topic: Topic) -> Data {
            let prefix = Data("libp2p-pubsub:".utf8)
            var messageBytes = Data()

            // Field 1: from (source peer ID bytes)
            let fromBytes = source.bytes
            messageBytes.append(0x0a) // tag 1, wire type 2 (length-delimited)
            messageBytes.append(contentsOf: Varint.encode(UInt64(fromBytes.count)))
            messageBytes.append(fromBytes)

            // Field 2: data
            messageBytes.append(0x12) // tag 2, wire type 2
            messageBytes.append(contentsOf: Varint.encode(UInt64(data.count)))
            messageBytes.append(data)

            // Field 3: seqno
            messageBytes.append(0x1a) // tag 3, wire type 2
            messageBytes.append(contentsOf: Varint.encode(UInt64(seqno.count)))
            messageBytes.append(seqno)

            // Field 4: topic
            let topicBytes = Data(topic.value.utf8)
            messageBytes.append(0x22) // tag 4, wire type 2
            messageBytes.append(contentsOf: Varint.encode(UInt64(topicBytes.count)))
            messageBytes.append(topicBytes)

            return prefix + messageBytes
        }

        /// Builds the message.
        ///
        /// - Returns: The constructed message
        /// - Throws: If required fields are missing
        public func build() throws -> GossipSubMessage {
            let seqno = sequenceNumber ?? Self.generateSequenceNumber()

            return GossipSubMessage(
                source: source,
                data: data,
                sequenceNumber: seqno,
                topic: topic,
                signature: signature,
                key: key
            )
        }
    }
}

// MARK: - Message Validation

extension GossipSubMessage {
    /// Validation result for a message.
    public enum ValidationResult: Sendable {
        /// Message is valid and should be propagated.
        case accept
        /// Message is invalid and should be rejected (penalize sender).
        case reject
        /// Message should be ignored (don't propagate, don't penalize).
        case ignore
    }

    /// Validates the message structure.
    ///
    /// - Returns: Whether the message has valid structure
    public func validateStructure() -> Bool {
        // Topic must not be empty
        guard !topic.value.isEmpty else { return false }

        // Sequence number must be 8 bytes (if present)
        if !sequenceNumber.isEmpty && sequenceNumber.count != 8 {
            return false
        }

        return true
    }

    /// Verifies the message signature.
    ///
    /// Per libp2p pubsub spec, the signature covers:
    /// - The message prefix "libp2p-pubsub:"
    /// - The protobuf-encoded message (source, seqno, topic, data)
    ///
    /// - Returns: Whether the signature is valid
    public func verifySignature() -> Bool {
        guard let signature = signature else {
            // No signature to verify
            return false
        }

        guard let source = source else {
            // Anonymous messages cannot have valid signatures
            return false
        }

        // Get the public key (either from `key` field or embedded in PeerID)
        let publicKey: PublicKey
        if let keyData = key {
            // Key is provided explicitly
            let pk: PublicKey
            do {
                pk = try PublicKey(protobufEncoded: keyData)
            } catch {
                return false
            }
            // Verify key matches source PeerID
            guard pk.peerID == source else {
                return false
            }
            publicKey = pk
        } else {
            // Try to extract from PeerID (only works for inline keys)
            let extractedKey: PublicKey?
            do {
                extractedKey = try source.extractPublicKey()
            } catch {
                return false
            }
            guard let pk = extractedKey else {
                return false
            }
            publicKey = pk
        }

        // Build signing data per libp2p pubsub spec
        let signingData = buildSigningData()

        // Verify signature
        do {
            return try publicKey.verify(signature: signature, for: signingData)
        } catch {
            return false
        }
    }

    /// Builds the data that should be signed.
    ///
    /// Format: "libp2p-pubsub:" + protobuf(from, seqno, topic, data)
    private func buildSigningData() -> Data {
        // Signature domain prefix
        let prefix = Data("libp2p-pubsub:".utf8)

        // Build protobuf-style message bytes (same order as wire format)
        var messageBytes = Data()

        // Field 1: from (source peer ID bytes)
        if let source = source {
            let fromBytes = source.bytes
            messageBytes.append(0x0a) // tag 1, wire type 2 (length-delimited)
            messageBytes.append(contentsOf: Varint.encode(UInt64(fromBytes.count)))
            messageBytes.append(fromBytes)
        }

        // Field 2: data
        messageBytes.append(0x12) // tag 2, wire type 2
        messageBytes.append(contentsOf: Varint.encode(UInt64(data.count)))
        messageBytes.append(data)

        // Field 3: seqno
        if !sequenceNumber.isEmpty {
            messageBytes.append(0x1a) // tag 3, wire type 2
            messageBytes.append(contentsOf: Varint.encode(UInt64(sequenceNumber.count)))
            messageBytes.append(sequenceNumber)
        }

        // Field 4: topic
        let topicBytes = Data(topic.value.utf8)
        messageBytes.append(0x22) // tag 4, wire type 2
        messageBytes.append(contentsOf: Varint.encode(UInt64(topicBytes.count)))
        messageBytes.append(topicBytes)

        return prefix + messageBytes
    }
}

// MARK: - ReceivedMessage

/// A message received from the network with metadata.
public struct ReceivedMessage: Sendable {
    /// The received message.
    public let message: GossipSubMessage

    /// The peer that sent us this message (may not be the original source).
    public let receivedFrom: PeerID

    /// When the message was received.
    public let receivedAt: ContinuousClock.Instant

    /// Creates a new received message.
    public init(message: GossipSubMessage, receivedFrom: PeerID) {
        self.message = message
        self.receivedFrom = receivedFrom
        self.receivedAt = .now
    }
}
