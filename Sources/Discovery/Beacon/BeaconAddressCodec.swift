import Foundation
import P2PCore

/// Utility to convert between OpaqueAddress and Multiaddr.
///
/// Maps medium IDs to the corresponding `MultiaddrProtocol` cases:
/// - "ble"         -> `.ble(data)`
/// - "wifi-direct" -> `.wifiDirect(data)`
/// - "lora"        -> `.lora(data)`
/// - "nfc"         -> `.nfc(data)`
public struct BeaconAddressCodec: Sendable {

    public init() {}

    /// Converts an OpaqueAddress to a Multiaddr.
    ///
    /// - Parameter address: The opaque address to convert.
    /// - Returns: A Multiaddr containing the appropriate transport protocol.
    /// - Throws: `BeaconAddressCodecError.unknownMedium` if the medium is not supported.
    public func toMultiaddr(_ address: OpaqueAddress) throws -> Multiaddr {
        let proto: MultiaddrProtocol
        switch address.mediumID {
        case "ble":
            proto = .ble(address.raw)
        case "wifi-direct":
            proto = .wifiDirect(address.raw)
        case "lora":
            proto = .lora(address.raw)
        case "nfc":
            proto = .nfc(address.raw)
        default:
            throw BeaconAddressCodecError.unknownMedium(address.mediumID)
        }
        return Multiaddr(uncheckedProtocols: [proto])
    }

    /// Converts multiple OpaqueAddresses to Multiaddrs, skipping any that fail.
    ///
    /// - Parameter addresses: The opaque addresses to convert.
    /// - Returns: An array of successfully converted Multiaddrs.
    public func toMultiaddrs(_ addresses: [OpaqueAddress]) -> [Multiaddr] {
        var result: [Multiaddr] = []
        result.reserveCapacity(addresses.count)
        for address in addresses {
            do {
                let multiaddr = try toMultiaddr(address)
                result.append(multiaddr)
            } catch {
                // Skip addresses with unknown media
                continue
            }
        }
        return result
    }

    /// Converts a Multiaddr to an OpaqueAddress.
    ///
    /// Extracts the first beacon-compatible protocol component from the Multiaddr.
    ///
    /// - Parameter multiaddr: The multiaddr to convert.
    /// - Returns: An OpaqueAddress, or nil if no beacon-compatible protocol is found.
    public func toOpaqueAddress(_ multiaddr: Multiaddr) -> OpaqueAddress? {
        for proto in multiaddr.protocols {
            switch proto {
            case .ble(let data):
                return OpaqueAddress(mediumID: "ble", raw: data)
            case .wifiDirect(let data):
                return OpaqueAddress(mediumID: "wifi-direct", raw: data)
            case .lora(let data):
                return OpaqueAddress(mediumID: "lora", raw: data)
            case .nfc(let data):
                return OpaqueAddress(mediumID: "nfc", raw: data)
            default:
                continue
            }
        }
        return nil
    }

    /// Converts multiple Multiaddrs to OpaqueAddresses, skipping incompatible ones.
    ///
    /// - Parameter multiaddrs: The multiaddrs to convert.
    /// - Returns: An array of successfully extracted OpaqueAddresses.
    public func toOpaqueAddresses(_ multiaddrs: [Multiaddr]) -> [OpaqueAddress] {
        multiaddrs.compactMap { toOpaqueAddress($0) }
    }
}

/// Errors that can occur during address conversion.
public enum BeaconAddressCodecError: Error, Sendable {
    /// The medium ID is not supported for Multiaddr conversion.
    case unknownMedium(String)
}
