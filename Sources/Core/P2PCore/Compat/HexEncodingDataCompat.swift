/// `Data` compatibility surface for the moved hex decoder.
///
/// The Embedded-clean core (``LibP2PCore``) exposes `Hex.decode(_:) -> [UInt8]?`.
/// This adapter restores the historical `Data(hexString:)` failable initializer
/// so existing callers and the test suite compile unchanged.

import Foundation
import LibP2PCore

extension Data {

    /// Creates `Data` from a hex string.
    ///
    /// - Parameter hexString: A hex-encoded string (e.g., "deadbeef").
    ///   Must have even length. Case-insensitive.
    /// - Returns: The decoded data, or `nil` if the string is invalid hex.
    public init?(hexString: String) {
        guard let bytes = Hex.decode(hexString) else { return nil }
        self = Data(bytes)
    }
}
