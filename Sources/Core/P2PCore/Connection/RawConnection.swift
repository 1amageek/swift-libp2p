import Foundation
import NIOCore

/// A raw network connection.
///
/// This protocol represents an unencrypted network connection
/// that provides basic read/write operations using ByteBuffer
/// for zero-copy data passing through the protocol pipeline.
public protocol RawConnection: Sendable {
    /// The local address of this connection.
    var localAddress: Multiaddr? { get }

    /// The remote address of this connection.
    var remoteAddress: Multiaddr { get }

    /// Reads data from the connection.
    func read() async throws -> ByteBuffer

    /// Writes data to the connection.
    func write(_ data: ByteBuffer) async throws

    /// Closes the connection.
    func close() async throws
}
