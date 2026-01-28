import Testing
import Foundation
@testable import P2PDiscovery
@testable import P2PCore

// MARK: - ProtoBook Tests

@Suite("ProtoBook Tests")
struct ProtoBookTests {

    @Test("setProtocols replaces all protocols for a peer")
    func setProtocolsReplacesAll() async {
        let book = MemoryProtoBook()
        let peer = KeyPair.generateEd25519().peerID

        await book.setProtocols(["/chat/1.0", "/ping/1.0"], for: peer)
        await book.setProtocols(["/new/1.0"], for: peer)

        let protocols = await book.protocols(for: peer)
        #expect(protocols.count == 1)
        #expect(protocols.contains("/new/1.0"))
    }

    @Test("addProtocols unions with existing protocols")
    func addProtocolsUnions() async {
        let book = MemoryProtoBook()
        let peer = KeyPair.generateEd25519().peerID

        await book.setProtocols(["/chat/1.0"], for: peer)
        await book.addProtocols(["/ping/1.0", "/chat/1.0"], for: peer)

        let protocols = await book.protocols(for: peer)
        #expect(protocols.count == 2)
        #expect(Set(protocols) == Set(["/chat/1.0", "/ping/1.0"]))
    }

    @Test("removeProtocols removes subset of protocols")
    func removeProtocolsSubset() async {
        let book = MemoryProtoBook()
        let peer = KeyPair.generateEd25519().peerID

        await book.setProtocols(["/chat/1.0", "/ping/1.0", "/kad/1.0"], for: peer)
        await book.removeProtocols(["/ping/1.0"], from: peer)

        let protocols = await book.protocols(for: peer)
        #expect(protocols.count == 2)
        #expect(Set(protocols) == Set(["/chat/1.0", "/kad/1.0"]))
    }

    @Test("removeProtocols cleans up peer entry when all protocols removed")
    func removeProtocolsCleansUp() async {
        let book = MemoryProtoBook()
        let peer = KeyPair.generateEd25519().peerID

        await book.setProtocols(["/chat/1.0"], for: peer)
        await book.removeProtocols(["/chat/1.0"], from: peer)

        let protocols = await book.protocols(for: peer)
        #expect(protocols.isEmpty)
    }

    @Test("protocols(for:) returns empty for unknown peer")
    func protocolsForUnknownPeer() async {
        let book = MemoryProtoBook()
        let peer = KeyPair.generateEd25519().peerID

        let protocols = await book.protocols(for: peer)
        #expect(protocols.isEmpty)
    }

    @Test("supportsProtocols filters to supported ones")
    func supportsProtocolsFilters() async {
        let book = MemoryProtoBook()
        let peer = KeyPair.generateEd25519().peerID

        await book.setProtocols(["/chat/1.0", "/ping/1.0"], for: peer)

        let supported = await book.supportsProtocols(
            ["/chat/1.0", "/kad/1.0", "/ping/1.0"],
            for: peer
        )
        #expect(supported.count == 2)
        #expect(Set(supported) == Set(["/chat/1.0", "/ping/1.0"]))
    }

    @Test("firstSupportedProtocol returns first match or nil")
    func firstSupportedProtocol() async {
        let book = MemoryProtoBook()
        let peer = KeyPair.generateEd25519().peerID

        await book.setProtocols(["/ping/1.0", "/kad/1.0"], for: peer)

        // Should return the first match in input order
        let first = await book.firstSupportedProtocol(
            ["/chat/1.0", "/kad/1.0", "/ping/1.0"],
            for: peer
        )
        #expect(first == "/kad/1.0")

        // No match
        let noMatch = await book.firstSupportedProtocol(
            ["/unknown/1.0"],
            for: peer
        )
        #expect(noMatch == nil)
    }

    @Test("removePeer clears all protocol data for a peer")
    func removePeerClearsAll() async {
        let book = MemoryProtoBook()
        let peer = KeyPair.generateEd25519().peerID

        await book.setProtocols(["/chat/1.0", "/ping/1.0"], for: peer)
        await book.removePeer(peer)

        let protocols = await book.protocols(for: peer)
        #expect(protocols.isEmpty)
    }

    @Test("peers(supporting:) returns matching peers")
    func peersSupporting() async {
        let book = MemoryProtoBook()
        let peer1 = KeyPair.generateEd25519().peerID
        let peer2 = KeyPair.generateEd25519().peerID
        let peer3 = KeyPair.generateEd25519().peerID

        await book.setProtocols(["/chat/1.0", "/ping/1.0"], for: peer1)
        await book.setProtocols(["/chat/1.0"], for: peer2)
        await book.setProtocols(["/kad/1.0"], for: peer3)

        let chatPeers = await book.peers(supporting: "/chat/1.0")
        #expect(chatPeers.count == 2)
        #expect(Set(chatPeers) == Set([peer1, peer2]))

        let kadPeers = await book.peers(supporting: "/kad/1.0")
        #expect(kadPeers.count == 1)
        #expect(kadPeers.contains(peer3))

        let unknownPeers = await book.peers(supporting: "/unknown/1.0")
        #expect(unknownPeers.isEmpty)
    }
}
