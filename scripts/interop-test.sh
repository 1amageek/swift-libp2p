#!/usr/bin/env bash
set -euo pipefail

mode="smoke"
test_timeout_seconds=90
build_timeout_seconds=900
skip_build=0
skip_tests=0
keep_running=0
project_name=""
artifact_dir=""
profile_overrides=()
filter_overrides=()
extra_swift_args=()

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/interop-test.sh [mode] [options] [-- <swift test args...>]

Modes:
  preflight   Check Docker Engine and Compose availability.
  build       Build the container images for the selected profile.
  smoke       Build Go/Rust QUIC images and run Ping/Identify interop tests.
  transport   Build transport images and run TCP/WebSocket/Noise/Yamux tests.
  protocol    Build protocol images and run GossipSub/Kademlia/Relay tests.
  full        Build all interop images and run the full interop suite.
  up          Start the selected Compose topology and keep it running.
  down        Stop the selected Compose topology.
  logs        Collect Compose and Docker diagnostics.

Options:
  --timeout S        Per-filter swift test timeout. Default: 90.
  --build-timeout S  Container build timeout. Default: 900.
  --project NAME     Compose project name. Default: swift-libp2p-interop-<pid>.
  --artifacts DIR    Artifact directory. Default: .test-artifacts/interop/<timestamp>.
  --profile PROFILE  Override Compose profile. Can be repeated.
  --filter FILTER    Override Swift test filter. Can be repeated.
  --skip-build       Do not build images before tests.
  --skip-tests       Build/start only; do not run Swift tests.
  --keep-running     Do not stop Compose services on exit.

Examples:
  scripts/interop-test.sh smoke
  scripts/interop-test.sh transport --timeout 120
  scripts/interop-test.sh full -- --disable-sandbox
EOF
  exit 2
}

if [[ $# -gt 0 && "$1" != --* ]]; then
  mode="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      test_timeout_seconds="$2"
      shift 2
      ;;
    --build-timeout)
      build_timeout_seconds="$2"
      shift 2
      ;;
    --project)
      project_name="$2"
      shift 2
      ;;
    --artifacts)
      artifact_dir="$2"
      shift 2
      ;;
    --profile)
      profile_overrides+=("$2")
      shift 2
      ;;
    --filter)
      filter_overrides+=("$2")
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --skip-tests)
      skip_tests=1
      shift
      ;;
    --keep-running)
      keep_running=1
      shift
      ;;
    --)
      shift
      extra_swift_args=("$@")
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

for value in "$test_timeout_seconds" "$build_timeout_seconds"; do
  [[ "$value" =~ ^[0-9]+$ ]] || usage
  (( value > 0 )) || usage
done

case "$mode" in
  preflight|build|smoke|transport|protocol|full|up|down|logs)
    ;;
  *)
    usage
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
interop_dir="$repo_root/Tests/Interop"
compose_file="$interop_dir/docker-compose.interop.yml"
timeout_runner="$script_dir/swift-test-timeout.sh"

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
if [[ -z "$project_name" ]]; then
  project_name="swift-libp2p-interop-$$"
fi
if [[ -z "$artifact_dir" ]]; then
  artifact_dir="$repo_root/.test-artifacts/interop/$timestamp"
fi

mkdir -p "$artifact_dir"
export SWIFT_LIBP2P_INTEROP_RUN_ID="$project_name"

compose_base=()

detect_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    compose_base=(
      docker compose
      --project-name "$project_name"
      --project-directory "$interop_dir"
      -f "$compose_file"
    )
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    compose_base=(
      docker-compose
      --project-name "$project_name"
      --project-directory "$interop_dir"
      -f "$compose_file"
    )
    return
  fi

  echo "Docker Compose is required. Install Docker Engine with Compose support." >&2
  exit 2
}

profiles_for_mode() {
  if (( ${#profile_overrides[@]} > 0 )); then
    printf '%s ' "${profile_overrides[@]}"
    return
  fi

  case "$mode" in
    smoke|preflight|build|up|down|logs)
      echo "smoke"
      ;;
    transport)
      echo "transport"
      ;;
    protocol)
      echo "protocol"
      ;;
    full)
      echo "full"
      ;;
  esac
}

filters_for_mode() {
  if (( ${#filter_overrides[@]} > 0 )); then
    printf '%s\n' "${filter_overrides[@]}"
    return
  fi

  case "$mode" in
    smoke)
      printf '%s\n' \
        "GoInteropTests.PingInteropTests" \
        "GoInteropTests.IdentifyInteropTests"
      ;;
    transport)
      printf '%s\n' \
        "GoInteropTests.TCPInteropTests" \
        "GoInteropTests.RustTCPInteropTests" \
        "GoInteropTests.WebSocketInteropTests" \
        "GoInteropTests.WSSInteropTests" \
        "GoInteropTests.NoiseInteropTests" \
        "GoInteropTests.YamuxInteropTests"
      ;;
    protocol)
      printf '%s\n' \
        "GoInteropTests.GossipSubInteropTests" \
        "GoInteropTests.KademliaInteropTests" \
        "GoInteropTests.CircuitRelayInteropTests"
      ;;
    full)
      printf '%s\n' \
        "GoInteropTests.PingInteropTests" \
        "GoInteropTests.IdentifyInteropTests" \
        "GoInteropTests.TCPInteropTests" \
        "GoInteropTests.RustTCPInteropTests" \
        "GoInteropTests.WebSocketInteropTests" \
        "GoInteropTests.WSSInteropTests" \
        "GoInteropTests.NoiseInteropTests" \
        "GoInteropTests.YamuxInteropTests" \
        "GoInteropTests.GossipSubInteropTests" \
        "GoInteropTests.KademliaInteropTests" \
        "GoInteropTests.CircuitRelayInteropTests" \
        "GoInteropTests.FullStackInteropTests"
      ;;
  esac
}

preflight() {
  command -v docker >/dev/null 2>&1 || {
    echo "Docker Engine is required." >&2
    exit 2
  }

  docker info >"$artifact_dir/docker-info.txt" 2>&1 || {
    echo "Docker Engine is not running or not reachable. See $artifact_dir/docker-info.txt" >&2
    exit 2
  }

  "${compose_base[@]}" version >"$artifact_dir/docker-compose-version.txt" 2>&1
  docker version >"$artifact_dir/docker-version.txt" 2>&1
}

collect_artifacts() {
  mkdir -p "$artifact_dir"

  docker ps -a >"$artifact_dir/docker-ps.txt" 2>&1 || true
  docker images \
    "go-libp2p*" \
    "rust-libp2p*" \
    >"$artifact_dir/docker-images.txt" 2>&1 || true

  "${compose_base[@]}" ps -a >"$artifact_dir/compose-ps.txt" 2>&1 || true
  "${compose_base[@]}" logs --no-color >"$artifact_dir/compose.log" 2>&1 || true
}

shutdown_topology() {
  if (( keep_running == 0 )); then
    local harness_containers
    harness_containers="$(docker ps -aq --filter "label=swift-libp2p.interop.run=$project_name" 2>/dev/null || true)"
    if [[ -n "$harness_containers" ]]; then
      docker rm -f $harness_containers >"$artifact_dir/harness-cleanup.log" 2>&1 || true
    fi
    "${compose_base[@]}" down --volumes --remove-orphans >"$artifact_dir/compose-down.log" 2>&1 || true
    docker ps -a >"$artifact_dir/docker-ps-after-cleanup.txt" 2>&1 || true
  fi
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  perl -e 'setpgrp(0,0) or die "setpgrp failed: $!"; exec @ARGV' "$@" &
  local runner_pid=$!
  local start_time
  start_time="$(date +%s)"

  while kill -0 "$runner_pid" 2>/dev/null; do
    local now elapsed
    now="$(date +%s)"
    elapsed=$(( now - start_time ))
    if (( elapsed >= timeout_seconds )); then
      echo "Timed out after ${timeout_seconds}s: $*" >&2
      kill -TERM "-$runner_pid" 2>/dev/null || true
      sleep 2
      kill -KILL "-$runner_pid" 2>/dev/null || true
      wait "$runner_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done

  wait "$runner_pid"
}

build_images() {
  local profiles
  read -r -a profiles <<<"$(profiles_for_mode)"
  local profile_args=()
  for profile in "${profiles[@]}"; do
    profile_args+=(--profile "$profile")
  done

  echo "==> Building interop images for profile(s): ${profiles[*]}"
  run_with_timeout \
    "$build_timeout_seconds" \
    "${compose_base[@]}" \
    "${profile_args[@]}" \
    build
}

start_topology() {
  local profiles
  read -r -a profiles <<<"$(profiles_for_mode)"
  local profile_args=()
  for profile in "${profiles[@]}"; do
    profile_args+=(--profile "$profile")
  done

  echo "==> Starting interop topology for profile(s): ${profiles[*]}"
  "${compose_base[@]}" "${profile_args[@]}" up -d
}

run_swift_tests() {
  [[ -x "$timeout_runner" ]] || {
    echo "Missing executable: $timeout_runner" >&2
    exit 2
  }

  local module_cache_dir="${SWIFTPM_MODULECACHE_OVERRIDE:-$repo_root/.cache/clang-interop}"
  mkdir -p "$module_cache_dir"
  export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_dir"

  cd "$repo_root"

  local base_args=(--disable-sandbox)
  if (( ${#extra_swift_args[@]} > 0 )); then
    base_args+=("${extra_swift_args[@]}")
  fi

  while IFS= read -r filter; do
    [[ -n "$filter" ]] || continue
    echo
    echo "==> Interop Swift test: $filter"
    "$timeout_runner" "$test_timeout_seconds" "${base_args[@]}" --filter "$filter"
  done < <(filters_for_mode)
}

detect_compose
preflight

exit_code=0
trap 'exit_code=$?; collect_artifacts; shutdown_topology; exit "$exit_code"' EXIT

case "$mode" in
  preflight)
    echo "Interop preflight passed. Artifacts: $artifact_dir"
    ;;
  logs)
    keep_running=1
    collect_artifacts
    echo "Interop artifacts collected: $artifact_dir"
    ;;
  down)
    shutdown_topology
    echo "Interop topology stopped: $project_name"
    ;;
  build)
    build_images
    echo "Interop images built. Artifacts: $artifact_dir"
    ;;
  up)
    if (( skip_build == 0 )); then
      build_images
    fi
    start_topology
    keep_running=1
    echo "Interop topology running: $project_name"
    ;;
  smoke|transport|protocol|full)
    if (( skip_build == 0 )); then
      build_images
    fi
    if (( skip_tests == 0 )); then
      run_swift_tests
    fi
    echo "Interop $mode passed. Artifacts: $artifact_dir"
    ;;
esac
