#!/usr/bin/env bash
set -euo pipefail

suites=(
  KademliaKeyBenchmarks
  MessageIDBenchmarks
  NoiseCryptoBenchmarks
  PartialSortBenchmarks
  TopicBenchmarks
  VarintBenchmarks
  YamuxFrameBenchmarks
)
configuration="debug"
timeout_seconds=120
build_timeout_seconds=240
extra_args=()

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/run-benchmarks.sh [--configuration debug|release] [--timeout S] [--build-timeout S] [--suite Name]... [-- <swift test args...>]

Examples:
  scripts/run-benchmarks.sh
  scripts/run-benchmarks.sh --configuration release
  scripts/run-benchmarks.sh --suite VarintBenchmarks --suite MessageIDBenchmarks
  scripts/run-benchmarks.sh --configuration release -- --parallel
EOF
  exit 2
}

selected_suites=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      configuration="$2"
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
    --suite)
      selected_suites+=("$2")
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

[[ "$configuration" == "debug" || "$configuration" == "release" ]] || usage
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || usage
[[ "$build_timeout_seconds" =~ ^[0-9]+$ ]] || usage
(( timeout_seconds > 0 )) || usage
(( build_timeout_seconds > 0 )) || usage

if (( ${#selected_suites[@]} > 0 )); then
  suites=("${selected_suites[@]}")
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
timeout_runner="$script_dir/swift-test-timeout.sh"
[[ -x "$timeout_runner" ]] || {
  echo "Missing executable: $timeout_runner" >&2
  exit 2
}

module_cache_dir="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.cache/clang}"
mkdir -p "$module_cache_dir"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_dir"

base_args=(--disable-sandbox)
if [[ "$configuration" == "release" ]]; then
  base_args+=(-c release)
fi
if (( ${#extra_args[@]} > 0 )); then
  base_args+=("${extra_args[@]}")
fi

run_index=0
for suite in "${suites[@]}"; do
  ((run_index += 1))

  filter="^P2PBenchmarks\\.${suite}$"
  run_args=("${base_args[@]}" --filter "$filter")
  run_timeout="$build_timeout_seconds"

  if (( run_index > 1 )); then
    run_args+=(--skip-build)
    run_timeout="$timeout_seconds"
  fi

  echo
  echo "==> [$run_index/${#suites[@]}] $suite ($configuration)"
  "$timeout_runner" "$run_timeout" "${run_args[@]}"
done
