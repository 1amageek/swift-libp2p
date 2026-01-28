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
}
