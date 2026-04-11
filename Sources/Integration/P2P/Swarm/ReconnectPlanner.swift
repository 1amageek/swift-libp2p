import P2PCore
import P2PRuntime

internal enum ReconnectAction: Sendable {
    case none
    case schedule(attempt: Int, delay: Duration)
    case fail(attempts: Int)
}

internal protocol ReconnectPlanner: Sendable {
    func action(
        localPeerID: PeerID,
        remotePeerID: PeerID,
        retryCount: Int,
        reason: DisconnectReason,
        hasReconnectAddress: Bool
    ) -> ReconnectAction
}

internal struct DefaultReconnectPlanner: ReconnectPlanner {
    private let policy: ReconnectionPolicy

    init(policy: ReconnectionPolicy) {
        self.policy = policy
    }

    func action(
        localPeerID: PeerID,
        remotePeerID: PeerID,
        retryCount: Int,
        reason: DisconnectReason,
        hasReconnectAddress: Bool
    ) -> ReconnectAction {
        guard hasReconnectAddress, localPeerID < remotePeerID else {
            return .none
        }

        if policy.shouldReconnect(attempt: retryCount, reason: reason) {
            let attempt = retryCount + 1
            return .schedule(attempt: attempt, delay: policy.delay(for: attempt - 1))
        }

        if retryCount >= policy.maxRetries {
            return .fail(attempts: retryCount)
        }

        return .none
    }
}
