/// XSalsa20 - Pure Swift implementation of the XSalsa20 stream cipher
///
/// XSalsa20 extends Salsa20 with a 24-byte nonce (vs 8-byte for Salsa20).
/// It uses HSalsa20 to derive a subkey from the first 16 bytes of the nonce,
/// then runs standard Salsa20 with the remaining 8 bytes of the nonce.
///
/// Reference: https://cr.yp.to/snuffle/xsalsa-20081128.pdf
import Foundation

// MARK: - Constants

/// Salsa20 "sigma" constant: "expand 32-byte k" as four little-endian uint32
private let sigma: [UInt32] = [
    0x61707865, // "expa"
    0x3320646e, // "nd 3"
    0x79622d32, // "2-by"
    0x6b206574, // "te k"
]

// MARK: - XSalsa20

/// XSalsa20 stream cipher (pure Swift implementation).
///
/// XSalsa20 = HSalsa20(key, nonce[0..16]) to derive subkey,
/// then Salsa20(subkey, nonce[16..24]) for keystream generation.
public struct XSalsa20: Sendable {
    /// The 4x4 uint32 state matrix for Salsa20.
    private var state: [UInt32]

    /// 64-bit block counter (low 32 bits at index 8, high 32 bits at index 9).
    private var counter: UInt64

    /// Remaining keystream bytes from current block.
    private var keystreamBuffer: [UInt8]

    /// Create cipher with key (32 bytes) and nonce (24 bytes).
    ///
    /// - Parameters:
    ///   - key: 32-byte encryption key (Pre-Shared Key)
    ///   - nonce: 24-byte nonce (randomly generated per connection)
    /// - Throws: `PnetError` if key or nonce length is invalid.
    public init(key: [UInt8], nonce: [UInt8]) throws {
        guard key.count == 32 else {
            throw PnetError.invalidKeyLength(expected: 32, got: key.count)
        }
        guard nonce.count == 24 else {
            throw PnetError.invalidNonceLength(expected: 24, got: nonce.count)
        }

        // Step 1: HSalsa20 to derive 32-byte subkey from key + nonce[0..16]
        let subkey = hsalsa20(key: key, input: Array(nonce[0..<16]))

        // Step 2: Set up Salsa20 state with subkey + nonce[16..24]
        //
        // State layout (4x4 matrix of uint32):
        //   sigma[0]  key[0..4]    key[4..8]    key[8..12]
        //   key[12..16] sigma[1]  nonce[0..4]  nonce[4..8]
        //   counter_lo  counter_hi sigma[2]    key[16..20]
        //   key[20..24] key[24..28] key[28..32] sigma[3]
        let n = Array(nonce[16..<24])
        self.state = [
            sigma[0],
            loadLE32(subkey, offset: 0),
            loadLE32(subkey, offset: 4),
            loadLE32(subkey, offset: 8),
            loadLE32(subkey, offset: 12),
            sigma[1],
            loadLE32(n, offset: 0),
            loadLE32(n, offset: 4),
            0,  // counter low
            0,  // counter high
            sigma[2],
            loadLE32(subkey, offset: 16),
            loadLE32(subkey, offset: 20),
            loadLE32(subkey, offset: 24),
            loadLE32(subkey, offset: 28),
            sigma[3],
        ]
        self.counter = 0
        self.keystreamBuffer = []
    }

    /// Encrypt/decrypt data in-place (XOR with keystream).
    ///
    /// Since XSalsa20 is a stream cipher using XOR, encryption and decryption
    /// are the same operation. This mutates because it advances the internal counter.
    ///
    /// - Parameter data: Data to encrypt/decrypt in-place.
    public mutating func process(_ data: inout [UInt8]) {
        var offset = 0
        while offset < data.count {
            // Refill keystream buffer if empty
            if keystreamBuffer.isEmpty {
                keystreamBuffer = generateBlock()
            }

            let available = keystreamBuffer.count
            let needed = data.count - offset
            let toProcess = min(available, needed)

            // XOR data with keystream
            for i in 0..<toProcess {
                data[offset + i] ^= keystreamBuffer[i]
            }

            offset += toProcess

            if toProcess == available {
                keystreamBuffer = []
            } else {
                keystreamBuffer = Array(keystreamBuffer[toProcess...])
            }
        }
    }

    /// Generate keystream bytes without any plaintext input.
    ///
    /// - Parameter count: Number of keystream bytes to generate.
    /// - Returns: The requested keystream bytes.
    public mutating func keystream(count: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        process(&result)
        return result
    }

    /// Generate a single 64-byte keystream block and advance the counter.
    private mutating func generateBlock() -> [UInt8] {
        // Set counter in state
        state[8] = UInt32(truncatingIfNeeded: counter)
        state[9] = UInt32(truncatingIfNeeded: counter >> 32)

        // Run Salsa20 core (20 rounds)
        let output = salsa20Core(input: state)

        // Convert output to bytes
        var bytes = [UInt8](repeating: 0, count: 64)
        for i in 0..<16 {
            storeLE32(&bytes, offset: i * 4, value: output[i])
        }

        counter += 1
        return bytes
    }
}

// MARK: - HSalsa20

/// HSalsa20: takes 32-byte key + 16-byte input, produces 32-byte output.
///
/// Used as the first step of XSalsa20 to extend the nonce from 24 to 8 bytes
/// by deriving a subkey. The output consists of words 0, 5, 10, 15, 6, 7, 8, 9
/// from the Salsa20 core state (before addition of input).
///
/// Reference: https://cr.yp.to/snuffle/xsalsa-20081128.pdf
internal func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
    precondition(key.count == 32, "HSalsa20 key must be 32 bytes")
    precondition(input.count == 16, "HSalsa20 input must be 16 bytes")

    // Set up initial state for HSalsa20
    // Layout:
    //   sigma[0]  key[0..4]    key[4..8]    key[8..12]
    //   key[12..16] sigma[1]  input[0..4]  input[4..8]
    //   input[8..12] input[12..16] sigma[2] key[16..20]
    //   key[20..24] key[24..28] key[28..32] sigma[3]
    var x: [UInt32] = [
        sigma[0],
        loadLE32(key, offset: 0),
        loadLE32(key, offset: 4),
        loadLE32(key, offset: 8),
        loadLE32(key, offset: 12),
        sigma[1],
        loadLE32(input, offset: 0),
        loadLE32(input, offset: 4),
        loadLE32(input, offset: 8),
        loadLE32(input, offset: 12),
        sigma[2],
        loadLE32(key, offset: 16),
        loadLE32(key, offset: 20),
        loadLE32(key, offset: 24),
        loadLE32(key, offset: 28),
        sigma[3],
    ]

    // 20 rounds (10 double-rounds)
    for _ in 0..<10 {
        // Column round
        quarterRound(&x, 0, 4, 8, 12)
        quarterRound(&x, 5, 9, 13, 1)
        quarterRound(&x, 10, 14, 2, 6)
        quarterRound(&x, 15, 3, 7, 11)
        // Diagonal round
        quarterRound(&x, 0, 1, 2, 3)
        quarterRound(&x, 5, 6, 7, 4)
        quarterRound(&x, 10, 11, 8, 9)
        quarterRound(&x, 15, 12, 13, 14)
    }

    // HSalsa20 output: words 0, 5, 10, 15, 6, 7, 8, 9
    // (NOT added to the original input, unlike regular Salsa20)
    var output = [UInt8](repeating: 0, count: 32)
    storeLE32(&output, offset: 0, value: x[0])
    storeLE32(&output, offset: 4, value: x[5])
    storeLE32(&output, offset: 8, value: x[10])
    storeLE32(&output, offset: 12, value: x[15])
    storeLE32(&output, offset: 16, value: x[6])
    storeLE32(&output, offset: 20, value: x[7])
    storeLE32(&output, offset: 24, value: x[8])
    storeLE32(&output, offset: 28, value: x[9])

    return output
}

// MARK: - Salsa20 Core

/// Salsa20 core function: 20 rounds of quarter-round operations on a 4x4 uint32 matrix.
///
/// Takes 16 uint32 input words and produces 16 uint32 output words.
/// The output is the input added to the result of 20 rounds of mixing.
///
/// - Parameter input: 16-element array of UInt32 (the state matrix).
/// - Returns: 16-element array of UInt32 (the mixed output).
internal func salsa20Core(input: [UInt32]) -> [UInt32] {
    precondition(input.count == 16, "Salsa20 core requires 16 uint32 words")

    var x = input

    // 20 rounds (10 double-rounds)
    for _ in 0..<10 {
        // Column round
        quarterRound(&x, 0, 4, 8, 12)
        quarterRound(&x, 5, 9, 13, 1)
        quarterRound(&x, 10, 14, 2, 6)
        quarterRound(&x, 15, 3, 7, 11)
        // Diagonal round
        quarterRound(&x, 0, 1, 2, 3)
        quarterRound(&x, 5, 6, 7, 4)
        quarterRound(&x, 10, 11, 8, 9)
        quarterRound(&x, 15, 12, 13, 14)
    }

    // Add original input to the mixed state
    for i in 0..<16 {
        x[i] = x[i] &+ input[i]
    }

    return x
}

// MARK: - Quarter Round

/// Salsa20 quarter-round function.
///
/// Operates on four elements of the state array:
///   b ^= (a + d) <<< 7
///   c ^= (b + a) <<< 9
///   d ^= (c + b) <<< 13
///   a ^= (d + c) <<< 18
///
/// - Parameters:
///   - x: State array (modified in-place)
///   - a, b, c, d: Indices into the state array
@inline(__always)
private func quarterRound(_ x: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
    x[b] ^= rotateLeft(x[a] &+ x[d], by: 7)
    x[c] ^= rotateLeft(x[b] &+ x[a], by: 9)
    x[d] ^= rotateLeft(x[c] &+ x[b], by: 13)
    x[a] ^= rotateLeft(x[d] &+ x[c], by: 18)
}

// MARK: - Utility Functions

/// Rotate a 32-bit value left by the specified number of bits.
@inline(__always)
private func rotateLeft(_ value: UInt32, by count: Int) -> UInt32 {
    (value << count) | (value >> (32 - count))
}

/// Load a little-endian 32-bit integer from a byte array at the given offset.
@inline(__always)
private func loadLE32(_ bytes: [UInt8], offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

/// Store a 32-bit integer as little-endian bytes into a byte array at the given offset.
@inline(__always)
private func storeLE32(_ bytes: inout [UInt8], offset: Int, value: UInt32) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}
