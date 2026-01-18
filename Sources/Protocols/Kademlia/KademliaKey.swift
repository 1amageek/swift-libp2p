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
public struct KademliaKey: Sendable, Hashable {
    /// The raw 256-bit key bytes (32 bytes).
    public let bytes: Data

    /// Creates a key from raw bytes.
    ///
    /// - Parameter bytes: The raw key bytes (must be 32 bytes).
    /// - Precondition: `bytes.count == 32`
    public init(bytes: Data) {
        precondition(bytes.count == 32, "KademliaKey must be 32 bytes")
        self.bytes = bytes
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
        self.bytes = bytes
    }

    /// Creates a key by hashing arbitrary data with SHA-256.
    ///
    /// - Parameter data: The data to hash.
    public init(hashing data: Data) {
        let hash = SHA256.hash(data: data)
        self.bytes = Data(hash)
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

    /// Calculates the XOR distance to another key.
    ///
    /// - Parameter other: The other key.
    /// - Returns: A new key representing the XOR distance.
    public func distance(to other: KademliaKey) -> KademliaKey {
        var result = Data(count: 32)
        for i in 0..<32 {
            result[i] = bytes[i] ^ other.bytes[i]
        }
        return KademliaKey(bytes: result)
    }

    /// Returns the number of leading zero bits in this key.
    ///
    /// This is used to determine the k-bucket index.
    public var leadingZeroBits: Int {
        for (byteIndex, byte) in bytes.enumerated() {
            if byte != 0 {
                // Count leading zeros in this byte
                return byteIndex * 8 + byte.leadingZeroBitCount
            }
        }
        return 256  // All zeros
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
    /// - Parameters:
    ///   - lhs: First key.
    ///   - rhs: Second key.
    /// - Returns: True if lhs < rhs.
    public static func < (lhs: KademliaKey, rhs: KademliaKey) -> Bool {
        for i in 0..<32 {
            if lhs.bytes[i] < rhs.bytes[i] { return true }
            if lhs.bytes[i] > rhs.bytes[i] { return false }
        }
        return false
    }

    /// Returns whether this key is closer to a target than another key.
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
        bytes.prefix(8).map { String(format: "%02x", $0) }.joined() + "..."
    }
}

// MARK: - Comparable

extension KademliaKey: Comparable {
    public static func == (lhs: KademliaKey, rhs: KademliaKey) -> Bool {
        lhs.bytes == rhs.bytes
    }
}
