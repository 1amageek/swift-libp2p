/// JSONTracer - JSON output tracer for GossipSub message flow.
///
/// Collects trace events in memory and provides JSON serialization.
/// Useful for debugging, testing, and offline analysis of GossipSub behavior.
import Foundation
import Synchronization
import P2PCore

/// A GossipSubTracer implementation that records events as JSON-serializable objects.
///
/// Events are stored in an internal buffer with a configurable maximum size.
/// When the buffer is full, the oldest events are discarded.
///
/// Thread-safe via Mutex for concurrent access from multiple GossipSub operations.
///
/// ## Usage
///
/// ```swift
/// let tracer = JSONTracer(maxEvents: 5000)
///
/// // ... attach to GossipSub service ...
///
/// // Retrieve events
/// let events = tracer.events()
///
/// // Serialize to JSON
/// let json = try tracer.eventsAsJSON()
/// ```
public final class JSONTracer: GossipSubTracer, Sendable {

    // MARK: - Types

    /// A single trace event captured by the tracer.
    public struct TraceEvent: Sendable, Codable {
        /// Unix epoch timestamp in seconds (with fractional part).
        public let timestamp: Double

        /// The event type identifier (e.g., "ADD_PEER", "DELIVER_MESSAGE").
        public let type: String

        /// The peer ID involved in the event, if applicable.
        public let peerID: String?

        /// The topic involved in the event, if applicable.
        public let topic: String?

        /// The hex-encoded message ID, if applicable.
        public let messageID: String?

        /// Additional key-value metadata for the event.
        public let extra: [String: String]?

        public init(
            timestamp: Double,
            type: String,
            peerID: String? = nil,
            topic: String? = nil,
            messageID: String? = nil,
            extra: [String: String]? = nil
        ) {
            self.timestamp = timestamp
            self.type = type
            self.peerID = peerID
            self.topic = topic
            self.messageID = messageID
            self.extra = extra
        }
    }

    // MARK: - CircularBuffer

    /// A simple offset-based circular buffer that avoids O(n) `removeFirst()`.
    ///
    /// Elements are appended to the end. When the logical count exceeds `maxSize`,
    /// the start offset advances (O(1)). The underlying storage is compacted when
    /// more than half of it is dead space, keeping amortised memory bounded.
    private struct CircularBuffer<T>: Sendable where T: Sendable {
        private var storage: [T] = []
        private var startIndex: Int = 0
        private let maxSize: Int

        init(maxSize: Int) {
            self.maxSize = maxSize
            self.storage.reserveCapacity(min(maxSize, 1024))
        }

        /// The number of live elements.
        var count: Int { storage.count - startIndex }

        /// Appends an element, evicting the oldest if at capacity.
        mutating func append(_ element: T) {
            storage.append(element)
            if storage.count - startIndex > maxSize {
                startIndex += 1
            }
            // Compact when more than half is unused
            if startIndex > maxSize {
                storage.removeFirst(startIndex)
                startIndex = 0
            }
        }

        /// Returns a snapshot of the live elements in order.
        func toArray() -> [T] {
            Array(storage[startIndex...])
        }

        /// Removes all elements.
        mutating func removeAll() {
            storage.removeAll()
            startIndex = 0
        }
    }

    // MARK: - State

    private struct TracerState: Sendable {
        var buffer: CircularBuffer<TraceEvent>
        let maxEvents: Int

        init(maxEvents: Int) {
            self.buffer = CircularBuffer(maxSize: maxEvents)
            self.maxEvents = maxEvents
        }

        mutating func append(_ event: TraceEvent) {
            buffer.append(event)
        }
    }

    private let state: Mutex<TracerState>

    // MARK: - Initialization

    /// Creates a new JSONTracer.
    ///
    /// - Parameter maxEvents: Maximum number of events to retain in the buffer.
    ///   When this limit is reached, the oldest events are discarded. Defaults to 10000.
    public init(maxEvents: Int = 10000) {
        self.state = Mutex(TracerState(maxEvents: maxEvents))
    }

    // MARK: - Query

    /// Returns a snapshot of all currently buffered trace events.
    ///
    /// - Returns: Array of trace events in chronological order
    public func events() -> [TraceEvent] {
        state.withLock { $0.buffer.toArray() }
    }

    /// Serializes all buffered events to JSON data.
    ///
    /// - Returns: JSON-encoded representation of all trace events
    /// - Throws: Encoding errors if serialization fails
    public func eventsAsJSON() throws -> Data {
        let snapshot = state.withLock { $0.buffer.toArray() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// Removes all buffered events.
    public func clear() {
        state.withLock { $0.buffer.removeAll() }
    }

    // MARK: - GossipSubTracer

    public func addPeer(_ peer: PeerID, protocol proto: String) {
        record(type: "ADD_PEER", peerID: peer.description, extra: ["protocol": proto])
    }

    public func removePeer(_ peer: PeerID) {
        record(type: "REMOVE_PEER", peerID: peer.description)
    }

    public func join(topic: String) {
        record(type: "JOIN", topic: topic)
    }

    public func leave(topic: String) {
        record(type: "LEAVE", topic: topic)
    }

    public func graft(peer: PeerID, topic: String) {
        record(type: "GRAFT", peerID: peer.description, topic: topic)
    }

    public func prune(peer: PeerID, topic: String) {
        record(type: "PRUNE", peerID: peer.description, topic: topic)
    }

    public func deliverMessage(id: Data, topic: String, from peer: PeerID, size: Int) {
        record(
            type: "DELIVER_MESSAGE",
            peerID: peer.description,
            topic: topic,
            messageID: id.hexEncodedString(),
            extra: ["size": String(size)]
        )
    }

    public func rejectMessage(id: Data, topic: String, from peer: PeerID, reason: RejectReason) {
        record(
            type: "REJECT_MESSAGE",
            peerID: peer.description,
            topic: topic,
            messageID: id.hexEncodedString(),
            extra: ["reason": reason.rawValue]
        )
    }

    public func duplicateMessage(id: Data, topic: String, from peer: PeerID) {
        record(
            type: "DUPLICATE_MESSAGE",
            peerID: peer.description,
            topic: topic,
            messageID: id.hexEncodedString()
        )
    }

    public func publishMessage(id: Data, topic: String) {
        record(
            type: "PUBLISH_MESSAGE",
            topic: topic,
            messageID: id.hexEncodedString()
        )
    }

    // MARK: - Private

    private func record(
        type: String,
        peerID: String? = nil,
        topic: String? = nil,
        messageID: String? = nil,
        extra: [String: String]? = nil
    ) {
        let event = TraceEvent(
            timestamp: Date().timeIntervalSince1970,
            type: type,
            peerID: peerID,
            topic: topic,
            messageID: messageID,
            extra: extra
        )
        state.withLock { $0.append(event) }
    }
}

// MARK: - Data Hex Extension

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
