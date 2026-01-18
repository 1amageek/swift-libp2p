/// PingPongDemo - Demonstrates TCP + Plaintext + Yamux working together
///
/// Run with: swift run PingPongDemo [server|client]
import Foundation
import P2P
import P2PTransportTCP
import P2PSecurityPlaintext
import P2PMuxYamux

@main
struct PingPongDemo {
    static func main() async throws {
        let args = CommandLine.arguments

        if args.count < 2 {
            print("Usage: PingPongDemo [server|client]")
            print("  server - Start a ping/pong server on port 4001")
            print("  client - Connect to server and send pings")
            return
        }

        switch args[1] {
        case "server":
            try await runServer()
        case "client":
            try await runClient()
        default:
            print("Unknown command: \(args[1])")
            print("Use 'server' or 'client'")
        }
    }

    static func runServer() async throws {
        print("Starting Ping/Pong Server...")

        let keyPair = KeyPair.generateEd25519()
        let listenAddr = Multiaddr.tcp(host: "127.0.0.1", port: 4001)

        // Configure node with all components upfront
        let node = Node(configuration: NodeConfiguration(
            keyPair: keyPair,
            listenAddresses: [listenAddr],
            transports: [TCPTransport()],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()]
        ))

        // Register ping handler
        await node.handle("/ping/1.0.0") { context in
            print("Received ping request from \(context.remotePeer)")
            do {
                while true {
                    let data = try await context.stream.read()
                    let message = String(decoding: data, as: UTF8.self)
                    print("  Received: \(message)")

                    if message == "ping" {
                        try await context.stream.write(Data("pong".utf8))
                        print("  Sent: pong")
                    }
                }
            } catch {
                print("  Stream closed: \(error)")
            }
        }

        try await node.start()

        print("Server listening on \(listenAddr)")
        print("PeerID: \(await node.peerID)")
        print("Press Ctrl+C to stop...")

        // Keep running
        try await Task.sleep(for: .seconds(3600))
    }

    static func runClient() async throws {
        print("Starting Ping/Pong Client...")

        let keyPair = KeyPair.generateEd25519()

        // Configure node with all components upfront
        let node = Node(configuration: NodeConfiguration(
            keyPair: keyPair,
            transports: [TCPTransport()],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()]
        ))

        try await node.start()

        print("Client PeerID: \(await node.peerID)")

        // Connect to server
        let serverAddr = Multiaddr.tcp(host: "127.0.0.1", port: 4001)
        print("Connecting to \(serverAddr)...")

        let remotePeer = try await node.connect(to: serverAddr)
        print("Connected to peer: \(remotePeer)")

        // Open a stream with protocol negotiation
        let stream = try await node.newStream(to: remotePeer, protocol: "/ping/1.0.0")
        print("Stream opened with /ping/1.0.0 protocol")

        // Send pings
        for i in 1...5 {
            print("Sending ping \(i)...")
            try await stream.write(Data("ping".utf8))

            let response = try await stream.read()
            let message = String(decoding: response, as: UTF8.self)
            print("Received: \(message)")

            try await Task.sleep(for: .seconds(1))
        }

        print("Done!")
        try await stream.close()
        await node.stop()
    }
}
