/// Tests for NATStatus and NATStatusTracker.

import Testing
import Foundation
@testable import P2PAutoNAT
@testable import P2PCore

@Suite("NATStatus Tests")
struct NATStatusTests {

    @Test("Initial status is unknown")
    func initialStatusUnknown() {
        let tracker = NATStatusTracker()
        #expect(tracker.status == .unknown)
        #expect(tracker.confidence == 0)
    }

    @Test("Status changes to public after enough reachable probes")
    func statusChangesToPublic() throws {
        var tracker = NATStatusTracker(minProbes: 3)

        let addr1 = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let addr2 = try Multiaddr("/ip4/203.0.113.1/tcp/4002")
        let addr3 = try Multiaddr("/ip4/203.0.113.1/tcp/4003")

        // First two probes - not enough yet
        _ = tracker.recordProbe(.reachable(addr1))
        #expect(tracker.status == .unknown)

        _ = tracker.recordProbe(.reachable(addr2))
        #expect(tracker.status == .unknown)

        // Third probe should change status
        let changed = tracker.recordProbe(.reachable(addr3))
        #expect(changed == true)
        #expect(tracker.status.isPublic)
    }

    @Test("Status changes to private after enough unreachable probes")
    func statusChangesToPrivate() {
        var tracker = NATStatusTracker(minProbes: 3)

        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))

        let changed = tracker.recordProbe(.unreachable(.dialError))
        #expect(changed == true)
        #expect(tracker.status == .privateBehindNAT)
    }

    @Test("Confidence increases with consistent results")
    func confidenceIncreases() throws {
        var tracker = NATStatusTracker(minProbes: 3, maxConfidence: 5)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Get to public status
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))

        let initialConfidence = tracker.confidence

        // More consistent probes increase confidence
        _ = tracker.recordProbe(.reachable(addr))
        #expect(tracker.confidence > initialConfidence)

        _ = tracker.recordProbe(.reachable(addr))
        #expect(tracker.confidence > initialConfidence + 1)
    }

    @Test("Confidence decreases with conflicting results")
    func confidenceDecreases() throws {
        var tracker = NATStatusTracker(minProbes: 3, maxConfidence: 5)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Build up some confidence
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))

        let highConfidence = tracker.confidence

        // Conflicting result should decrease confidence
        _ = tracker.recordProbe(.unreachable(.dialError))
        #expect(tracker.confidence < highConfidence)
    }

    @Test("Reset clears status and confidence")
    func resetClearsState() throws {
        var tracker = NATStatusTracker(minProbes: 3)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Get to a known status
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        #expect(tracker.status.isPublic)

        // Reset
        tracker.reset()
        #expect(tracker.status == .unknown)
        #expect(tracker.confidence == 0)
    }

    @Test("Error probes are ignored for status determination")
    func errorProbesIgnored() throws {
        var tracker = NATStatusTracker(minProbes: 3)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Mix of errors and reachable
        _ = tracker.recordProbe(.error("timeout"))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.error("connection refused"))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.error("network unreachable"))

        // Still unknown because only 2 valid probes
        #expect(tracker.status == .unknown)

        // Third valid probe should change status
        _ = tracker.recordProbe(.reachable(addr))
        #expect(tracker.status.isPublic)
    }
}

@Suite("ProbeResult Tests")
struct ProbeResultTests {

    @Test("isReachable returns correct value")
    func isReachableCorrect() throws {
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        #expect(ProbeResult.reachable(addr).isReachable == true)
        #expect(ProbeResult.unreachable(.dialError).isReachable == false)
        #expect(ProbeResult.error("test").isReachable == false)
    }

    @Test("reachableAddress returns address for reachable")
    func reachableAddressCorrect() throws {
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        #expect(ProbeResult.reachable(addr).reachableAddress == addr)
        #expect(ProbeResult.unreachable(.dialError).reachableAddress == nil)
        #expect(ProbeResult.error("test").reachableAddress == nil)
    }
}

@Suite("NATStatus Transition Tests")
struct NATStatusTransitionTests {

    @Test("Status transitions from public to private")
    func statusTransitionPublicToPrivate() throws {
        var tracker = NATStatusTracker(minProbes: 3)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // First establish public status
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        #expect(tracker.status.isPublic)

        // Now add enough unreachable probes to flip to private
        // Need to overwhelm the reachable ones
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))

        // Should now be private (4 unreachable vs 3 reachable)
        #expect(tracker.status == .privateBehindNAT)
    }

    @Test("Status transitions from private to public")
    func statusTransitionPrivateToPublic() throws {
        var tracker = NATStatusTracker(minProbes: 3)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // First establish private status
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        #expect(tracker.status == .privateBehindNAT)

        // Now add enough reachable probes to flip to public
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))

        // Should now be public (4 reachable vs 3 unreachable)
        #expect(tracker.status.isPublic)
    }

    @Test("Old probes are removed when history exceeds maxHistory")
    func historyExceedsMaxHistory() throws {
        // Create tracker with small maxHistory for testing
        var tracker = NATStatusTracker(minProbes: 3, maxHistory: 5)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Fill history with reachable probes
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))

        // Should be public with 5 reachable probes
        #expect(tracker.status.isPublic)

        // Now add unreachable probes - old reachable ones should be evicted
        _ = tracker.recordProbe(.unreachable(.dialError))  // History: 4 reachable, 1 unreachable
        _ = tracker.recordProbe(.unreachable(.dialError))  // History: 3 reachable, 2 unreachable
        _ = tracker.recordProbe(.unreachable(.dialError))  // History: 2 reachable, 3 unreachable

        // Should now be private (3 unreachable vs 2 reachable)
        #expect(tracker.status == .privateBehindNAT)
    }

    @Test("Status does not change on tie")
    func statusTieKeepsCurrent() throws {
        var tracker = NATStatusTracker(minProbes: 3)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Establish public status first
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        #expect(tracker.status.isPublic)

        // Add equal unreachable probes (tie situation)
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))

        // On tie, status should remain unchanged (still public)
        #expect(tracker.status.isPublic)
    }

    @Test("Confidence resets on status transition")
    func confidenceResetsOnTransition() throws {
        var tracker = NATStatusTracker(minProbes: 3, maxConfidence: 10)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Build up confidence in public status
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))

        let highConfidence = tracker.confidence
        #expect(highConfidence >= 3)  // At least 3 probes worth

        // Add enough unreachable to transition
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))

        // Status should have transitioned
        #expect(tracker.status == .privateBehindNAT)
        // Confidence may be lower due to conflicting probes
        #expect(tracker.confidence < highConfidence)
    }
}

@Suite("NATStatus Error Handling Tests")
struct NATStatusErrorHandlingTests {

    @Test("Error results do not affect confidence when status is public")
    func errorResultsNoConfidenceChange() throws {
        var tracker = NATStatusTracker(minProbes: 3, maxConfidence: 5)
        let addr = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Get to public status with some confidence
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))
        _ = tracker.recordProbe(.reachable(addr))

        let confidenceBefore = tracker.confidence

        // Error result should not change confidence
        _ = tracker.recordProbe(.error("timeout"))

        #expect(tracker.confidence == confidenceBefore)
        #expect(tracker.status.isPublic)
    }

    @Test("Error results do not affect confidence when status is private")
    func errorResultsNoConfidenceChangePrivate() {
        var tracker = NATStatusTracker(minProbes: 3, maxConfidence: 5)

        // Get to private status with some confidence
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))
        _ = tracker.recordProbe(.unreachable(.dialError))

        let confidenceBefore = tracker.confidence

        // Error result should not change confidence
        _ = tracker.recordProbe(.error("connection refused"))

        #expect(tracker.confidence == confidenceBefore)
        #expect(tracker.status == .privateBehindNAT)
    }
}
