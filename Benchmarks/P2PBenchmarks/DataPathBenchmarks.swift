import Foundation
import Testing
import NIOCore
import P2PCore
import P2PMux
import P2PMuxYamux
import P2PRuntime
import P2PSecurity
import P2PSecurityNoise
import P2PSecurityPlaintext
import P2PSecurityTLS
import P2PTransportMemory

@Suite("Data Path Benchmarks", .serialized)
struct DataPathBenchmarks {
    private enum HarnessError: Error {
        case invalidEcho(expectedBytes: Int, actualBytes: Int)
    }

    @Test("Memory + Plaintext + Yamux connect")
    func connectPlaintextYamux() async throws {
        let factory = try await ConnectionPairFactory(security: PlaintextUpgrader())
        defer { Task { await factory.shutdown() } }

        try await benchmark("Memory+Plaintext+Yamux connect", iterations: 2_000) {
            let pair = try await factory.connect()
            await pair.shutdown()
        }
    }

    @Test("Memory + Noise + Yamux connect")
    func connectNoiseYamux() async throws {
        let factory = try await ConnectionPairFactory(security: NoiseUpgrader())
        defer { Task { await factory.shutdown() } }

        try await benchmark("Memory+Noise+Yamux connect", iterations: 500) {
            let pair = try await factory.connect()
            await pair.shutdown()
        }
    }

    @Test("Memory + TLS + Yamux connect")
    func connectTLSYamux() async throws {
        let factory = try await ConnectionPairFactory(security: TLSUpgrader())
        defer { Task { await factory.shutdown() } }

        try await benchmark("Memory+TLS+Yamux connect", iterations: 500) {
            let pair = try await factory.connect()
            await pair.shutdown()
        }
    }

    @Test("Memory + Plaintext + Yamux roundtrip 1KB")
    func roundtripPlaintextYamux1KB() async throws {
        let factory = try await ConnectionPairFactory(security: PlaintextUpgrader())
        let pair = try await factory.connect()
        let streamPair = try await pair.openStreamPair()
        let payload = Self.payload(size: 1024)

        defer {
            Task {
                await streamPair.shutdown()
                await pair.shutdown()
                await factory.shutdown()
            }
        }

        try await streamPair.roundTrip(payload)

        try await benchmarkThroughput(
            "Memory+Plaintext+Yamux roundtrip 1KB",
            iterations: 5_000,
            bytesPerIteration: payload.readableBytes * 2
        ) {
            try await streamPair.roundTrip(payload)
        }
    }

    @Test("Memory + Noise + Yamux roundtrip 1KB")
    func roundtripNoiseYamux1KB() async throws {
        let factory = try await ConnectionPairFactory(security: NoiseUpgrader())
        let pair = try await factory.connect()
        let streamPair = try await pair.openStreamPair()
        let payload = Self.payload(size: 1024)

        defer {
            Task {
                await streamPair.shutdown()
                await pair.shutdown()
                await factory.shutdown()
            }
        }

        try await streamPair.roundTrip(payload)

        try await benchmarkThroughput(
            "Memory+Noise+Yamux roundtrip 1KB",
            iterations: 2_000,
            bytesPerIteration: payload.readableBytes * 2
        ) {
            try await streamPair.roundTrip(payload)
        }
    }

    @Test("Memory + TLS + Yamux roundtrip 1KB")
    func roundtripTLSYamux1KB() async throws {
        let factory = try await ConnectionPairFactory(security: TLSUpgrader())
        let pair = try await factory.connect()
        let streamPair = try await pair.openStreamPair()
        let payload = Self.payload(size: 1024)

        defer {
            Task {
                await streamPair.shutdown()
                await pair.shutdown()
                await factory.shutdown()
            }
        }

        try await streamPair.roundTrip(payload)

        try await benchmarkThroughput(
            "Memory+TLS+Yamux roundtrip 1KB",
            iterations: 1_000,
            bytesPerIteration: payload.readableBytes * 2
        ) {
            try await streamPair.roundTrip(payload)
        }
    }

    @Test("Memory + Noise + Yamux roundtrip 32KB")
    func roundtripNoiseYamux32KB() async throws {
        let factory = try await ConnectionPairFactory(security: NoiseUpgrader())
        let pair = try await factory.connect()
        let streamPair = try await pair.openStreamPair()
        let payload = Self.payload(size: 32 * 1024)

        defer {
            Task {
                await streamPair.shutdown()
                await pair.shutdown()
                await factory.shutdown()
            }
        }

        try await streamPair.roundTrip(payload)

        try await benchmarkThroughput(
            "Memory+Noise+Yamux roundtrip 32KB",
            iterations: 500,
            bytesPerIteration: payload.readableBytes * 2
        ) {
            try await streamPair.roundTrip(payload)
        }
    }

    private static func payload(size: Int) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.reserveCapacity(size)
        for index in 0..<size {
            buffer.writeInteger(UInt8(truncatingIfNeeded: index))
        }
        return buffer
    }

    private struct ConnectionPairFactory {
        let clientIdentity: LocalIdentity
        let serverIdentity: LocalIdentity
        let clientProvider: any ConnectionProvider
        let serverListener: any ConnectionAcceptor

        init(security: any SecurityUpgrader) async throws {
            let hub = MemoryHub()
            let address = Multiaddr.memory(id: UUID().uuidString)
            let transport = MemoryTransport(hub: hub)
            let clientProvider = ConnectionProviders.pipeline(
                transport: transport,
                security: [security],
                muxers: [YamuxMuxer()]
            )
            let serverProvider = ConnectionProviders.pipeline(
                transport: transport,
                security: [security],
                muxers: [YamuxMuxer()]
            )

            self.clientIdentity = LocalIdentity(keyPair: .generateEd25519())
            self.serverIdentity = LocalIdentity(keyPair: .generateEd25519())
            self.clientProvider = clientProvider
            self.serverListener = try await serverProvider.listen(address, identity: serverIdentity)
        }

        func connect() async throws -> ConnectionPair {
            async let pendingCandidate = serverListener.accept()
            async let pendingClient = clientProvider.dial(serverListener.localAddress, identity: clientIdentity)

            let candidate = try await pendingCandidate
            let serverSession = try await candidate.establish()
            let clientSession = try await pendingClient

            return ConnectionPair(
                clientSession: clientSession,
                serverSession: serverSession
            )
        }

        func shutdown() async {
            do {
                try await serverListener.close()
            } catch {
            }
        }
    }

    private struct ConnectionPair {
        let clientSession: any StreamSession
        let serverSession: any StreamSession

        func openStreamPair() async throws -> StreamPair {
            async let pendingServerStream = serverSession.acceptStream()
            let clientStream = try await clientSession.newStream()
            let serverStream = try await pendingServerStream

            return StreamPair(
                clientStream: clientStream,
                serverStream: serverStream
            )
        }

        func shutdown() async {
            do {
                try await clientSession.close()
            } catch {
            }
            do {
                try await serverSession.close()
            } catch {
            }
        }
    }

    private actor StreamPair {
        let clientStream: any StreamChannel
        let serverStream: any StreamChannel
        private var clientReadBuffer = ByteBuffer()
        private var serverReadBuffer = ByteBuffer()

        init(
            clientStream: any StreamChannel,
            serverStream: any StreamChannel
        ) {
            self.clientStream = clientStream
            self.serverStream = serverStream
        }

        func roundTrip(_ payload: ByteBuffer) async throws {
            try await clientStream.writeLengthPrefixedMessage(payload)
            var serverReadBuffer = self.serverReadBuffer
            let received = try await serverStream.readLengthPrefixedMessage(buffer: &serverReadBuffer)
            self.serverReadBuffer = serverReadBuffer
            try await serverStream.writeLengthPrefixedMessage(received)
            var clientReadBuffer = self.clientReadBuffer
            let echoed = try await clientStream.readLengthPrefixedMessage(buffer: &clientReadBuffer)
            self.clientReadBuffer = clientReadBuffer
            blackHole(echoed)

            if echoed.readableBytes != payload.readableBytes {
                throw HarnessError.invalidEcho(
                    expectedBytes: payload.readableBytes,
                    actualBytes: echoed.readableBytes
                )
            }
        }

        func shutdown() async {
            await closeStream(clientStream)
            await closeStream(serverStream)
        }

        private func closeStream(_ stream: any StreamChannel) async {
            do {
                try await stream.reset()
            } catch {
            }
        }
    }
}
