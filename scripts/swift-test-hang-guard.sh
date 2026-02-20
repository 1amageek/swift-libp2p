#!/usr/bin/env bash
set -euo pipefail

repeats=3
timeout_seconds=30
build_timeout_seconds=120

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/swift-test-hang-guard.sh [--repeats N] [--timeout S] [--build-timeout S] -- <swift test args...>

Example:
  scripts/swift-test-hang-guard.sh --repeats 3 --timeout 30 --build-timeout 120 -- --disable-sandbox --filter P2PTransportWebSocketTests
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeats)
      repeats="$2"
      shift 2
      ;;
    --timeout)
      timeout_seconds="$2"
      shift 2
      ;;
    --build-timeout)
      build_timeout_seconds="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
done

[[ $# -gt 0 ]] || usage
[[ "$repeats" =~ ^[0-9]+$ ]] || usage
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || usage
[[ "$build_timeout_seconds" =~ ^[0-9]+$ ]] || usage
(( repeats > 0 )) || usage
(( timeout_seconds > 0 )) || usage
(( build_timeout_seconds > 0 )) || usage

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
timeout_runner="$script_dir/swift-test-timeout.sh"
[[ -x "$timeout_runner" ]] || {
  echo "Missing executable: $timeout_runner" >&2
  exit 2
}

module_cache_dir="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.cache/clang}"
mkdir -p "$module_cache_dir"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_dir"

lock_root="$PWD/.test-artifacts/hang-guard"
mkdir -p "$lock_root"
lock_dir="$lock_root/.lock"

release_lock() {
  if [[ -f "$lock_dir/pid" ]] && [[ "$(cat "$lock_dir/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" > "$lock_dir/pid"
    return
  fi

  local lock_pid=""
  if [[ -f "$lock_dir/pid" ]]; then
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  fi

  if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
    rm -rf "$lock_dir"
    mkdir "$lock_dir"
    echo "$$" > "$lock_dir/pid"
    return
  fi

  if [[ -n "$lock_pid" ]]; then
    echo "Another hang-guard run is active (pid: $lock_pid). Run tests serially." >&2
  else
    echo "Another hang-guard run is active. Run tests serially." >&2
  fi
  exit 3
}

acquire_lock
trap release_lock EXIT INT TERM

timestamp="$(date '+%Y%m%d-%H%M%S')-$$"
log_dir="$(mktemp -d "$lock_root/$timestamp.XXXXXX")"
mkdir -p "$log_dir"

helper_pattern="swiftpm-testing-helper.*$PWD/.build"

list_helpers() {
  pgrep -af "$helper_pattern" || true
}

collect_diagnostics() {
  local run_id="$1"
  local diag_file="$log_dir/run-${run_id}.diag.txt"
  {
    echo "time: $(date '+%F %T')"
    echo "pwd: $PWD"
    echo "helper_pattern: $helper_pattern"
    echo "--- helpers ---"
    list_helpers
    echo "--- ps (swift-related) ---"
    ps -o pid,ppid,stat,etime,pcpu,command -ax | rg 'swiftpm-testing-helper|swift-test|swift test' || true
    echo "--- .build/.lock ---"
    if [[ -f .build/.lock ]]; then
      cat .build/.lock
    else
      echo "no lock file"
    fi
  } >"$diag_file" 2>&1
}

base_args=("$@")

cold_args=()
for arg in "${base_args[@]}"; do
  if [[ "$arg" == "--skip-build" ]]; then
    continue
  fi
  cold_args+=("$arg")
done

warm_args=("${base_args[@]}")
has_skip_build=0
for arg in "${warm_args[@]}"; do
  if [[ "$arg" == "--skip-build" ]]; then
    has_skip_build=1
    break
  fi
done
if (( has_skip_build == 0 )); then
  warm_args+=("--skip-build")
fi

echo "Hang guard logs: $log_dir"

if [[ -n "$(list_helpers)" ]]; then
  echo "Found existing swiftpm-testing-helper processes; refusing to run concurrently." >&2
  collect_diagnostics "preflight"
  echo "See: $log_dir/run-preflight.diag.txt" >&2
  exit 3
fi

for i in $(seq 1 "$repeats"); do
  if (( i == 1 )); then
    run_timeout="$build_timeout_seconds"
    run_args=("${cold_args[@]}")
  else
    run_timeout="$timeout_seconds"
    run_args=("${warm_args[@]}")
  fi

  run_log="$log_dir/run-${i}.log"
  echo "Run $i/$repeats (timeout ${run_timeout}s): swift test ${run_args[*]}"

  set +e
  "$timeout_runner" "$run_timeout" "${run_args[@]}" >"$run_log" 2>&1
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    echo "Run $i failed with exit code $rc (see $run_log)" >&2
    collect_diagnostics "$i"
    exit "$rc"
  fi

  if [[ -n "$(list_helpers)" ]]; then
    echo "Run $i left stale swiftpm-testing-helper processes" >&2
    collect_diagnostics "$i"
    exit 1
  fi
done

echo "OK: $repeats run(s) completed without timeout or stale helper"
