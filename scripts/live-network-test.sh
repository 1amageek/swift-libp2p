#!/usr/bin/env bash
set -euo pipefail

timeout_seconds=90
build_timeout_seconds=180
extra_args=()

filters=(
  "P2PTransportTests"
  "P2PTransportWebSocketTests"
  "P2PTransportWebTransportTests"
  "P2PTransportQUICTests"
  "P2PPingTests"
  "P2PIdentifyTests"
  "P2PNATTests"
  "P2PDiscoveryWiFiBeaconTests"
  "P2PDiscoveryTests"
  "P2PTransportWebRTCTests.WebRTCE2ETests/clientServerHandshake"
  "P2PTransportWebRTCTests.WebRTCE2ETests/multipleClients"
  "P2PTransportWebRTCTests.WebRTCE2ETests/bidirectionalStream"
  "P2PTransportWebRTCTests.WebRTCE2ETests/multipleStreams"
  "P2PTransportWebRTCTests.WebRTCE2ETests/manySequentialBidirectionalStreams"
  "P2PTransportWebRTCTests.WebRTCE2ETests/concurrentBidirectionalStreamsDoNotCrossTalk"
  "P2PTransportWebRTCTests.WebRTCE2ETests/serverInitiatedStreamsAreFullDuplex"
  "P2PTransportWebRTCTests.WebRTCE2ETests/connectionStream"
  "P2PTransportWebRTCTests.WebRTCE2ETests/sequentialReconnectsReleaseListenerRoutes"
  "P2PTransportWebRTCTests.WebRTCE2ETests/inboundStreamIteration"
  "P2PTransportWebRTCTests.WebRTCE2ETests/peerIDMismatchRejected"
  "P2PTransportWebRTCTests.WebRTCE2ETests/wrongCerthashDigestRejected"
  "P2PTransportWebRTCTests.WebRTCE2ETests/bindFailureThrowsSocketBindFailed"
  "P2PTransportWebRTCTests.WebRTCE2ETests/unresolvableSocketAddressThrowsInvalidAddress"
  "P2PTransportWebRTCTests.WebRTCE2ETests/closedListenerFinishesConnectionsStream"
  "P2PTransportWebRTCTests.WebRTCE2ETests/lateDataOnClosedStreamDoesNotPoisonConnection"
  "P2PTransportWebRTCTests.WebRTCE2ETests/invalidMultiaddrThrows"
  "P2PTransportWebRTCTests.WebRTCTransportTests/inboundCapacityIsEnforcedBeforeRawAccept"
  "P2PTransportWebRTCTests.WebRTCTransportTests/inboundCapacitySlotReleasedAfterClose"
)

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/live-network-test.sh [--timeout S] [--build-timeout S] [--filter FILTER]... [-- <swift test args...>]

Examples:
  scripts/live-network-test.sh
  scripts/live-network-test.sh --filter P2PTransportWebSocketTests
  scripts/live-network-test.sh --filter P2PTransportWebRTCTests.WebRTCE2ETests/clientServerHandshake
EOF
  exit 2
}

selected_filters=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      timeout_seconds="$2"
      shift 2
      ;;
    --build-timeout)
      build_timeout_seconds="$2"
      shift 2
      ;;
    --filter)
      selected_filters+=("$2")
      shift 2
      ;;
    --)
      shift
      extra_args=("$@")
      break
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || usage
[[ "$build_timeout_seconds" =~ ^[0-9]+$ ]] || usage
(( timeout_seconds > 0 )) || usage
(( build_timeout_seconds > 0 )) || usage

if (( ${#selected_filters[@]} > 0 )); then
  filters=("${selected_filters[@]}")
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
timeout_runner="$script_dir/swift-test-timeout.sh"
[[ -x "$timeout_runner" ]] || {
  echo "Missing executable: $timeout_runner" >&2
  exit 2
}

export SWIFT_LIBP2P_ENABLE_LIVE_NETWORK_TESTS=1

cd "$repo_root"

base_args=(--disable-sandbox --no-parallel)
if (( ${#extra_args[@]} > 0 )); then
  base_args+=("${extra_args[@]}")
fi

run_index=0
for filter in "${filters[@]}"; do
  ((run_index += 1))
  run_args=("${base_args[@]}" --filter "$filter")
  run_timeout="$build_timeout_seconds"
  if (( run_index > 1 )); then
    run_args+=(--skip-build)
    run_timeout="$timeout_seconds"
  fi

  echo
  echo "==> [$run_index/${#filters[@]}] $filter"
  "$timeout_runner" "$run_timeout" "${run_args[@]}"
done
