/// ConnectionTrimmedContext - Structured metadata for trim events
///
/// Carries machine-readable trim decision details for monitoring.

import Foundation

/// Structured context for a trimmed connection event.
public struct ConnectionTrimmedContext: Sendable {
    /// Candidate rank in trim priority order (1 = highest trim priority).
    public let rank: Int?

    /// Number of tags on the trimmed connection.
    public let tagCount: Int

    /// Idle duration at trim time.
    public let idleDuration: Duration

    /// Connection direction of the trimmed connection.
    public let direction: ConnectionDirection

    public init(
        rank: Int?,
        tagCount: Int,
        idleDuration: Duration,
        direction: ConnectionDirection
    ) {
        self.rank = rank
        self.tagCount = tagCount
        self.idleDuration = idleDuration
        self.direction = direction
    }
}
