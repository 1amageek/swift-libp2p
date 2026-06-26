import Foundation

public let liveNetworkTestsEnabled =
    ProcessInfo.processInfo.environment["SWIFT_LIBP2P_ENABLE_LIVE_NETWORK_TESTS"] == "1"
