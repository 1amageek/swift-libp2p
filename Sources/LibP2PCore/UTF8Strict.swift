/// Strict UTF-8 decoding (Embedded-clean).
///
/// Embedded-clean: no Foundation. Wraps the standard-library
/// `String(validating:as:)` initializer (SE-0405), which validates the input and
/// returns `nil` on malformed UTF-8 — matching the historical Foundation
/// `String(bytes:encoding:.utf8)` semantics the codecs relied on. This is NOT the
/// lossy `String(decoding:as:)` (which substitutes U+FFFD); callers that frame
/// protocol tokens / protobuf strings need rejection, not substitution.

/// Decodes `bytes` as UTF-8, rejecting (returning `nil`) any malformed input.
///
/// - Parameter bytes: The candidate UTF-8 bytes.
/// - Returns: The decoded `String`, or `nil` if `bytes` is not valid UTF-8.
@inlinable
public func decodeUTF8Strict(_ bytes: [UInt8]) -> String? {
    String(validating: bytes, as: UTF8.self)
}
