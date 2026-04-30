#!/usr/bin/env bash
set -euo pipefail

include_benchmarks=0
include_interop=1
test_timeout_seconds=60
build_timeout_seconds=240
benchmark_timeout_seconds=600
benchmark_build_timeout_seconds=600
interop_mode="smoke"
interop_timeout_seconds=90
interop_build_timeout_seconds=900
extra_args=()

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/production-gate.sh [--skip-interop] [--interop-mode MODE] [--include-benchmarks] [--timeout S] [--build-timeout S] [--benchmark-timeout S] [--benchmark-build-timeout S] [-- <swift test args...>]

Examples:
  scripts/production-gate.sh
  scripts/production-gate.sh --include-benchmarks
  scripts/production-gate.sh --skip-interop
  scripts/production-gate.sh --timeout 90 --build-timeout 300
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-benchmarks)
      include_benchmarks=1
      shift
      ;;
    --skip-interop)
      include_interop=0
      shift
      ;;
    --interop-mode)
      interop_mode="$2"
      shift 2
      ;;
    --interop-timeout)
      interop_timeout_seconds="$2"
      shift 2
      ;;
    --interop-build-timeout)
      interop_build_timeout_seconds="$2"
      shift 2
      ;;
    --timeout)
      test_timeout_seconds="$2"
      shift 2
      ;;
    --build-timeout)
      build_timeout_seconds="$2"
      shift 2
      ;;
    --benchmark-timeout)
      benchmark_timeout_seconds="$2"
      shift 2
      ;;
    --benchmark-build-timeout)
      benchmark_build_timeout_seconds="$2"
      shift 2
      ;;
    --)
      shift
      extra_args=("$@")
      break
      ;;
    *)
      usage
      ;;
  esac
done

for value in \
  "$test_timeout_seconds" \
  "$build_timeout_seconds" \
  "$benchmark_timeout_seconds" \
  "$benchmark_build_timeout_seconds" \
  "$interop_timeout_seconds" \
  "$interop_build_timeout_seconds"
do
  [[ "$value" =~ ^[0-9]+$ ]] || usage
  (( value > 0 )) || usage
done

case "$interop_mode" in
  smoke|transport|protocol|full)
    ;;
  *)
    usage
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
timeout_runner="$script_dir/swift-test-timeout.sh"
benchmark_runner="$script_dir/run-benchmarks.sh"
interop_runner="$script_dir/interop-test.sh"

[[ -x "$timeout_runner" ]] || {
  echo "Missing executable: $timeout_runner" >&2
  exit 2
}
[[ -x "$benchmark_runner" ]] || {
  echo "Missing executable: $benchmark_runner" >&2
  exit 2
}
[[ -x "$interop_runner" ]] || {
  echo "Missing executable: $interop_runner" >&2
  exit 2
}

module_cache_root="${repo_root}/.cache"
mkdir -p "$module_cache_root"
module_cache_dir="${module_cache_root}/clang-production-gate"
rm -rf "$module_cache_dir"
mkdir -p "$module_cache_dir"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_dir"

cd "$repo_root"

base_args=(--disable-sandbox)
if (( ${#extra_args[@]} > 0 )); then
  base_args+=("${extra_args[@]}")
fi

run_suite() {
  local timeout_seconds="$1"
  local filter="$2"
  echo
  echo "==> $filter"
  "$timeout_runner" "$timeout_seconds" "${base_args[@]}" --filter "$filter"
}

run_suite "$build_timeout_seconds" "DataPathCopyGuardTests"
run_suite "$test_timeout_seconds" "NodeDSLTests"
run_suite "$test_timeout_seconds" "NodeE2ETests"

if (( include_interop == 1 )); then
  echo
  echo "==> Interop release gate ($interop_mode)"
  interop_args=(
    "$interop_mode"
    --timeout "$interop_timeout_seconds"
    --build-timeout "$interop_build_timeout_seconds"
  )
  if (( ${#extra_args[@]} > 0 )); then
    interop_args+=(-- "${extra_args[@]}")
  fi
  "$interop_runner" "${interop_args[@]}"
fi

if (( include_benchmarks == 1 )); then
  echo
  echo "==> Production benchmark snapshot"
  "$benchmark_runner" \
    --configuration release \
    --timeout "$benchmark_timeout_seconds" \
    --build-timeout "$benchmark_build_timeout_seconds" \
    --suite DataPathBenchmarks \
    --suite NoiseCryptoBenchmarks
fi
