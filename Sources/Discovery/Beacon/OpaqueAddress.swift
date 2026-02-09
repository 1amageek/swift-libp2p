import Foundation

/// A transport-specific address. Only the originating TransportAdapter can interpret its contents.
public struct OpaqueAddress: Hashable, Sendable, Codable {
    /// The medium that owns this address (e.g., "ble", "wifi-direct", "lora").
    public let mediumID: String

    /// Raw address bytes (opaque to all layers except L0).
    public let raw: Data

    public init(mediumID: String, raw: Data) {
        self.mediumID = mediumID
        self.raw = raw
    }
}

extension OpaqueAddress: CustomStringConvertible {
    public var description: String {
        "OpaqueAddress(\(mediumID), \(raw.count)B)"
    }
}
