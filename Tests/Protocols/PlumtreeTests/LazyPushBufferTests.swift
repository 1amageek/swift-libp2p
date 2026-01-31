import Testing
import Foundation
import P2PCore
@testable import P2PPlumtree

@Suite("LazyPushBuffer Tests")
struct LazyPushBufferTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func makeIHave(seq: UInt64 = 0) -> PlumtreeIHaveEntry {
        let source = makePeerID()
        return PlumtreeIHaveEntry(
            messageID: PlumtreeMessageID.compute(source: source, sequenceNumber: seq),
            topic: "test"
        )
    }

    @Test("Empty buffer")
    func emptyBuffer() {
        let buffer = LazyPushBuffer(maxBatchSize: 50)
        #expect(buffer.totalCount == 0)
        #expect(buffer.peerCount == 0)

        let flushed = buffer.flush()
        #expect(flushed.isEmpty)
    }

    @Test("Add and flush single entry")
    func addAndFlushSingle() {
        let buffer = LazyPushBuffer(maxBatchSize: 50)
        let peer = makePeerID()
        let entry = makeIHave()

        buffer.add(entry, for: peer)
        #expect(buffer.totalCount == 1)
        #expect(buffer.peerCount == 1)

        let flushed = buffer.flush()
        #expect(flushed.count == 1)
        #expect(flushed[peer]?.count == 1)
        #expect(flushed[peer]?[0] == entry)

        // After flush, buffer should be empty
        #expect(buffer.totalCount == 0)
    }

    @Test("Add entries for multiple peers")
    func multiplePeers() {
        let buffer = LazyPushBuffer(maxBatchSize: 50)
        let peer1 = makePeerID()
        let peer2 = makePeerID()
        let entry1 = makeIHave(seq: 1)
        let entry2 = makeIHave(seq: 2)

        buffer.add(entry1, for: peer1)
        buffer.add(entry2, for: peer2)

        #expect(buffer.totalCount == 2)
        #expect(buffer.peerCount == 2)

        let flushed = buffer.flush()
        #expect(flushed.count == 2)
        #expect(flushed[peer1]?.count == 1)
        #expect(flushed[peer2]?.count == 1)
    }

    @Test("Add entry for multiple peers at once")
    func addForMultiplePeers() {
        let buffer = LazyPushBuffer(maxBatchSize: 50)
        let peers = (0..<3).map { _ in makePeerID() }
        let entry = makeIHave()

        buffer.add(entry, for: peers)
        #expect(buffer.totalCount == 3)
        #expect(buffer.peerCount == 3)

        let flushed = buffer.flush()
        for peer in peers {
            #expect(flushed[peer]?.count == 1)
        }
    }

    @Test("Respects max batch size")
    func maxBatchSize() {
        let buffer = LazyPushBuffer(maxBatchSize: 2)
        let peer = makePeerID()

        for i in 0..<5 {
            buffer.add(makeIHave(seq: UInt64(i)), for: peer)
        }

        // Should cap at 2 entries per peer
        #expect(buffer.totalCount == 2)

        let flushed = buffer.flush()
        #expect(flushed[peer]?.count == 2)
    }

    @Test("Remove peer clears entries")
    func removePeer() {
        let buffer = LazyPushBuffer(maxBatchSize: 50)
        let peer = makePeerID()
        buffer.add(makeIHave(), for: peer)
        #expect(buffer.totalCount == 1)

        buffer.remove(peer: peer)
        #expect(buffer.totalCount == 0)
        #expect(buffer.peerCount == 0)
    }

    @Test("Clear removes all entries")
    func clear() {
        let buffer = LazyPushBuffer(maxBatchSize: 50)
        let peers = (0..<3).map { _ in makePeerID() }
        for peer in peers {
            buffer.add(makeIHave(), for: peer)
        }
        #expect(buffer.totalCount == 3)

        buffer.clear()
        #expect(buffer.totalCount == 0)
        #expect(buffer.peerCount == 0)
    }

    @Test("Flush returns and clears")
    func flushClearsState() {
        let buffer = LazyPushBuffer(maxBatchSize: 50)
        let peer = makePeerID()
        buffer.add(makeIHave(), for: peer)

        let first = buffer.flush()
        #expect(first.count == 1)

        let second = buffer.flush()
        #expect(second.isEmpty)
    }
}
