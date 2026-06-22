/// NATPortMapperError - Errors from NATPortMapper
import Foundation

/// Errors from NATPortMapper.
public enum NATPortMapperError: Error, Sendable {
    /// No gateway was discovered.
    case noGatewayFound
    /// Gateway discovery timed out.
    case discoveryTimeout
    /// Failed to get external address.
    case externalAddressUnavailable
    /// Port mapping request failed.
    case mappingFailed(String)
    /// Port already in use.
    case portInUse
    /// Gateway rejected the request.
    case requestDenied(String)
    /// Network error.
    case networkError(String)
    /// Invalid response from gateway.
    case invalidResponse
    /// Service is shutdown.
    case shutdown
    /// A gateway-supplied URL (SSDP LOCATION or SOAP control URL) failed
    /// validation: wrong scheme, non-LAN host, or host mismatch. Prevents SSRF.
    case untrustedGatewayURL(String)
    /// A gateway-returned external IP failed validation (unspecified, loopback,
    /// private, link-local, multicast, or otherwise non-routable bogon).
    case invalidExternalAddress(String)
    /// A UDP response arrived from a source other than the expected gateway.
    case unexpectedResponseSource(String)
}
