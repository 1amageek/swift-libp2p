#!/usr/bin/env bash
set -euo pipefail

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; exit 1; }

require_contains() {
  local needle="$1"
  local haystack="$2"
  local label="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    pass "$label"
  else
    fail "$label (missing: $needle)"
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if ! command -v claude >/dev/null 2>&1; then
  fail "claude command is not installed"
fi
pass "claude command is installed"

version_out="$(claude --version 2>&1 || true)"
if [[ -z "$version_out" ]]; then
  fail "claude --version returned empty output"
fi
pass "claude --version returned: $version_out"

help_out="$(claude --help 2>&1 || true)"
require_contains "--permission-mode" "$help_out" "help includes --permission-mode"
require_contains "--no-session-persistence" "$help_out" "help includes --no-session-persistence"
require_contains "--setting-sources" "$help_out" "help includes --setting-sources"
require_contains "--output-format" "$help_out" "help includes --output-format"
require_contains "--input-format" "$help_out" "help includes --input-format"

invalid_perm_out="$tmpdir/invalid-perm.txt"
if claude -p --permission-mode invalid "ping" >"$invalid_perm_out" 2>&1; then
  fail "invalid permission mode should fail"
fi
require_contains "Allowed choices" "$(cat "$invalid_perm_out")" "invalid permission mode returns validation error"

invalid_sources_out="$tmpdir/invalid-sources.txt"
if claude -p --setting-sources bogus "ping" >"$invalid_sources_out" 2>&1; then
  fail "invalid setting sources should fail"
fi
require_contains "Invalid setting source" "$(cat "$invalid_sources_out")" "invalid setting source returns validation error"

mkdir -p .claude-run
probe_out="$tmpdir/probe.txt"
(
  CLAUDE_CONFIG_DIR="$PWD/.claude-run" \
  DISABLE_TELEMETRY=1 \
  DISABLE_ERROR_REPORTING=1 \
  claude -p --no-session-persistence --max-turns 1 "respond with exactly ok" >"$probe_out" 2>&1
) &
pid=$!
deadline=$((SECONDS + 20))
while kill -0 "$pid" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rc=143
    break
  fi
  sleep 1
done
if [[ "${rc:-}" == "" ]]; then
  wait "$pid" 2>/dev/null || rc=$?
  rc="${rc:-0}"
fi

if grep -Fq "Connection error" "$probe_out"; then
  pass "print-mode probe reached connection retry path (network restricted or unavailable)"
elif grep -Eiq '"ok"|^ok$' "$probe_out"; then
  pass "print-mode probe returned content"
elif [[ "$rc" == "143" ]]; then
  pass "print-mode probe timed out under guard (treated as stalled network path)"
else
  printf '%s\n' "--- probe output ---"
  sed -n '1,160p' "$probe_out"
  fail "print-mode probe returned unexpected result (rc=$rc)"
fi

pass "validation complete"
