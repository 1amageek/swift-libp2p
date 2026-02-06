import Testing
import Foundation
@testable import P2PTransport
@testable import P2PCore

@Suite("Transport Tests")
struct TransportTests {

    // MARK: - TransportError

    @Test("TransportError cases are distinct")
    func transportErrorCases() throws {
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

        let unsupported = TransportError.unsupportedAddress(addr)
        let connFailed = TransportError.connectionFailed(underlying: NSError(domain: "test", code: 1))
        let listenerClosed = TransportError.listenerClosed
        let timeout = TransportError.timeout
        let unsupportedOp = TransportError.unsupportedOperation("test")

        _ = unsupported
        _ = connFailed
        _ = listenerClosed
        _ = timeout
        _ = unsupportedOp
    }

    @Test("TransportError.unsupportedAddress carries the address")
    func unsupportedAddressCarriesAddr() throws {
        let addr = try Multiaddr("/ip4/10.0.0.1/tcp/8080")
        let error = TransportError.unsupportedAddress(addr)

        if case .unsupportedAddress(let a) = error {
            #expect(a == addr)
        } else {
            Issue.record("Expected unsupportedAddress")
        }
    }

    @Test("TransportError.connectionFailed wraps underlying error")
    func connectionFailedUnderlying() {
        let underlying = NSError(domain: "net", code: 99)
        let error = TransportError.connectionFailed(underlying: underlying)

        if case .connectionFailed(let inner) = error {
            let nsError = inner as NSError
            #expect(nsError.code == 99)
        } else {
            Issue.record("Expected connectionFailed")
        }
    }

    @Test("TransportError.unsupportedOperation carries message")
    func unsupportedOperationMessage() {
        let error = TransportError.unsupportedOperation("QUIC not available")

        if case .unsupportedOperation(let msg) = error {
            #expect(msg == "QUIC not available")
        } else {
            Issue.record("Expected unsupportedOperation")
        }
    }

    @Test("TransportError.connectionClosed convenience")
    func connectionClosedConvenience() {
        let error = TransportError.connectionClosed
        if case .connectionFailed(let inner) = error {
            #expect(inner is ConnectionClosedError)
        } else {
            Issue.record("Expected connectionFailed wrapping ConnectionClosedError")
        }
    }

    // MARK: - ConnectionClosedError

    @Test("ConnectionClosedError description")
    func connectionClosedDescription() {
        let error = ConnectionClosedError()
        #expect(error.description == "Connection closed")
    }
}
