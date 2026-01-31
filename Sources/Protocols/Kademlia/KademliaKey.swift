/// KademliaKey - 256-bit key with XOR distance metric for Kademlia DHT.

import Foundation
import Crypto
import P2PCore

/// Errors that can occur when validating a KademliaKey.
public enum KademliaKeyError: Error, Sendable, Equatable {
    /// The key has an invalid length.
    case invalidLength(actual: Int, expected: Int)
}

/// A 256-bit key used in the Kademlia DHT.
///
/// Keys are derived from the SHA-256 hash of the input data.
/// Distance between keys is calculated using XOR.
///
/// Internally stores 32 bytes as 4 × UInt64 (big-endian) on the stack,
/// eliminating heap allocation for XOR distance, comparison, and leading-zero-bit operations.
public struct KademliaKey: Sendable, Hashable {
    /// Four 64-bit words representing the 256-bit key (big-endian byte order).
    public let w0, w1, w2, w3: UInt64

    /// Creates a key from four 64-bit words.
    ///
    /// - Parameters:
    ///   - w0: Bytes 0-7 (big-endian)
    ///   - w1: Bytes 8-15
    ///   - w2: Bytes 16-23
    ///   - w3: Bytes 24-31
    public init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
    }

    /// Creates a key from raw bytes.
    ///
    /// - Parameter bytes: The raw key bytes (must be 32 bytes).
    /// - Precondition: `bytes.count == 32`
    public init(bytes: Data) {
        precondition(bytes.count == 32, "KademliaKey must be 32 bytes")
        self = bytes.withUnsafeBytes { ptr in
            KademliaKey(
                w0: ptr.load(fromByteOffset: 0, as: UInt64.self).bigEndian,
                w1: ptr.load(fromByteOffset: 8, as: UInt64.self).bigEndian,
                w2: ptr.load(fromByteOffset: 16, as: UInt64.self).bigEndian,
                w3: ptr.load(fromByteOffset: 24, as: UInt64.self).bigEndian
            )
        }
    }

    /// Creates a key from raw bytes with validation.
    ///
    /// Use this initializer for untrusted input (e.g., from network messages).
    ///
    /// - Parameter bytes: The raw key bytes (must be 32 bytes).
    /// - Throws: `KademliaKeyError.invalidLength` if bytes is not 32 bytes.
    public init(validating bytes: Data) throws {
        guard bytes.count == 32 else {
            throw KademliaKeyError.invalidLength(actual: bytes.count, expected: 32)
        }
        self.init(bytes: bytes)
    }

    /// Creates a key by hashing arbitrary data with SHA-256.
    ///
    /// - Parameter data: The data to hash.
    public init(hashing data: Data) {
        let hash = SHA256.hash(data: data)
        let temp = Data(hash)
        self.init(bytes: temp)
    }

    /// Creates a key from a PeerID.
    ///
    /// - Parameter peerID: The peer ID to derive the key from.
    public init(from peerID: PeerID) {
        self.init(hashing: peerID.bytes)
    }

    /// Creates a key from a string (hashed).
    ///
    /// - Parameter string: The string to hash.
    public init(from string: String) {
        self.init(hashing: Data(string.utf8))
    }

    /// The raw 256-bit key bytes (32 bytes).
    ///
    /// This is a computed property that reconstructs Data from the internal
    /// UInt64 representation. Prefer using the UInt64 accessors (w0-w3)
    /// for performance-sensitive operations.
    public var bytes: Data {
        var data = Data(count: 32)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: w0.bigEndian, toByteOffset: 0, as: UInt64.self)
            ptr.storeBytes(of: w1.bigEndian, toByteOffset: 8, as: UInt64.self)
            ptr.storeBytes(of: w2.bigEndian, toByteOffset: 16, as: UInt64.self)
            ptr.storeBytes(of: w3.bigEndian, toByteOffset: 24, as: UInt64.self)
        }
        return data
    }

    /// Calculates the XOR distance to another key.
    ///
    /// Zero-allocation: the result is computed entirely on the stack.
    ///
    /// - Parameter other: The other key.
    /// - Returns: A new key representing the XOR distance.
    public func distance(to other: KademliaKey) -> KademliaKey {
        KademliaKey(
            w0: w0 ^ other.w0,
            w1: w1 ^ other.w1,
            w2: w2 ^ other.w2,
            w3: w3 ^ other.w3
        )
    }

    /// Returns the number of leading zero bits in this key.
    ///
    /// Uses hardware `leadingZeroBitCount` on UInt64 for maximum speed.
    /// This is used to determine the k-bucket index.
    public var leadingZeroBits: Int {
        if w0 != 0 { return w0.leadingZeroBitCount }
        if w1 != 0 { return 64 + w1.leadingZeroBitCount }
        if w2 != 0 { return 128 + w2.leadingZeroBitCount }
        if w3 != 0 { return 192 + w3.leadingZeroBitCount }
        return 256
    }

    /// Returns the k-bucket index for a peer at this distance.
    ///
    /// Bucket 0 is for the farthest peers (distance starts with 1).
    /// Bucket 255 is for the closest peers (distance starts with 255 zeros).
    ///
    /// - Returns: The bucket index (0-255), or nil if distance is zero (same key).
    public var bucketIndex: Int? {
        let zeros = leadingZeroBits
        if zeros >= 256 {
            return nil  // Same key
        }
        return 255 - zeros
    }

    /// Compares two keys numerically (as big-endian integers).
    ///
    /// Uses at most 4 integer comparisons instead of 32 byte comparisons.
    ///
    /// - Parameters:
    ///   - lhs: First key.
    ///   - rhs: Second key.
    /// - Returns: True if lhs < rhs.
    public static func < (lhs: KademliaKey, rhs: KademliaKey) -> Bool {
        if lhs.w0 != rhs.w0 { return lhs.w0 < rhs.w0 }
        if lhs.w1 != rhs.w1 { return lhs.w1 < rhs.w1 }
        if lhs.w2 != rhs.w2 { return lhs.w2 < rhs.w2 }
        return lhs.w3 < rhs.w3
    }

    /// Returns whether this key is closer to a target than another key.
    ///
    /// Zero-allocation: both distance computations are on the stack.
    ///
    /// - Parameters:
    ///   - target: The target key.
    ///   - other: The key to compare against.
    /// - Returns: True if self is closer to target than other.
    public func isCloser(to target: KademliaKey, than other: KademliaKey) -> Bool {
        let selfDistance = self.distance(to: target)
        let otherDistance = other.distance(to: target)
        return selfDistance < otherDistance
    }
}

extension KademliaKey: CustomStringConvertible {
    public var description: String {
        // Format first 8 bytes from w0 (big-endian)
        let b = w0.bigEndian
        return withUnsafeBytes(of: b) { ptr in
            ptr.map { String(format: "%02x", $0) }.joined()
        } + "..."
    }
}

// MARK: - Comparable

extension KademliaKey: Comparable {
    public static func == (lhs: KademliaKey, rhs: KademliaKey) -> Bool {
        lhs.w0 == rhs.w0 && lhs.w1 == rhs.w1 && lhs.w2 == rhs.w2 && lhs.w3 == rhs.w3
    }
}
