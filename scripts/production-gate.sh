#!/usr/bin/env bash
set -euo pipefail

include_benchmarks=0
test_timeout_seconds=60
build_timeout_seconds=240
benchmark_timeout_seconds=600
benchmark_build_timeout_seconds=600
extra_args=()

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/production-gate.sh [--include-benchmarks] [--timeout S] [--build-timeout S] [--benchmark-timeout S] [--benchmark-build-timeout S] [-- <swift test args...>]

Examples:
  scripts/production-gate.sh
  scripts/production-gate.sh --include-benchmarks
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
  "$benchmark_build_timeout_seconds"
do
  [[ "$value" =~ ^[0-9]+$ ]] || usage
  (( value > 0 )) || usage
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
timeout_runner="$script_dir/swift-test-timeout.sh"
benchmark_runner="$script_dir/run-benchmarks.sh"

[[ -x "$timeout_runner" ]] || {
  echo "Missing executable: $timeout_runner" >&2
  exit 2
}
[[ -x "$benchmark_runner" ]] || {
  echo "Missing executable: $benchmark_runner" >&2
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
