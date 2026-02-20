#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <timeout-seconds> <swift test args...>" >&2
  echo "Example: $0 30 --disable-sandbox --filter P2PTransportWebSocketTests" >&2
  exit 2
fi

timeout_seconds="$1"
shift

if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [[ "$timeout_seconds" -le 0 ]]; then
  echo "timeout-seconds must be a positive integer: $timeout_seconds" >&2
  exit 2
fi

module_cache_dir="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.cache/clang}"
mkdir -p "$module_cache_dir"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_dir"

# Run swift test in a separate process group so timeout can terminate all children.
perl -e 'setpgrp(0,0) or die "setpgrp failed: $!"; exec @ARGV' swift test "$@" &
runner_pid=$!

start_time="$(date +%s)"
timed_out=0

while kill -0 "$runner_pid" 2>/dev/null; do
  now="$(date +%s)"
  elapsed=$(( now - start_time ))
  if (( elapsed >= timeout_seconds )); then
    timed_out=1
    break
  fi
  sleep 1
done

if (( timed_out == 1 )); then
  echo "Timed out after ${timeout_seconds}s: swift test $*" >&2
  kill -TERM "-$runner_pid" 2>/dev/null || true
  sleep 2
  kill -KILL "-$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || true
  exit 124
fi

set +e
wait "$runner_pid"
exit_code=$?
set -e
exit "$exit_code"
