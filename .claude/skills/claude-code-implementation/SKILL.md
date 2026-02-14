---
name: claude-code-implementation
description: "Delegate coding tasks to Claude Code CLI with a strict workflow: clarify scope, present explicit cautions before implementation, run Claude for implementation, then perform mandatory post-implementation verification (diff review, targeted tests, and regression checks). Use when the user wants Claude Code to implement changes instead of direct manual edits."
---

# Claude Code Implementation

## Overview
Use Claude Code as the implementation engine while enforcing quality gates before and after coding.

## Workflow

### 1. Confirm scope and constraints
- Identify target files, non-goals, and acceptance criteria.
- Confirm environment constraints: build/test command, timeout, and permission mode.
- Refuse broad implementation until scope is concrete.

### 1.5 Run CLI preflight checks (mandatory)
Before using Claude Code for implementation, verify the local CLI contract:
- `claude --version` succeeds.
- Required options exist in `claude --help`:
  - `--permission-mode`
  - `--no-session-persistence`
  - `--setting-sources`
  - `--output-format`
  - `--input-format`
- Invalid-arg behavior is explicit and non-zero exit:
  - `claude -p --permission-mode invalid "ping"` must fail.
  - `claude -p --setting-sources bogus "ping"` must fail.

Use the helper script:
```bash
bash .claude/skills/claude-code-implementation/scripts/validate-claude-code.sh
```

### 2. Present cautions before implementation (mandatory)
Before running Claude Code, provide a short caution brief that includes:
- Change scope boundaries.
- Risky areas and expected side effects.
- Verification plan to run after implementation.
- Rollback/containment approach if checks fail.

Do not start implementation until this caution brief is explicit.

### 3. Prepare an implementation prompt for Claude Code
Write a structured prompt with these sections:
- Goal
- Constraints
- Files to modify
- Required checks
- Output format

Keep prompts instruction-focused. Do not use few-shot examples.

### 4. Execute Claude Code
Use one of these modes:
- Interactive:
```bash
claude --permission-mode acceptEdits
```
- Non-interactive:
```bash
claude -p "<structured_prompt>" --permission-mode acceptEdits
```

Prefer project-root execution so relative paths are stable.

In sandboxed environments, always set runtime env explicitly:
```bash
CLAUDE_CONFIG_DIR="$PWD/.claude-run" \
DISABLE_TELEMETRY=1 \
DISABLE_ERROR_REPORTING=1 \
claude -p --no-session-persistence --permission-mode acceptEdits "<structured_prompt>"
```

This avoids writes to non-writable home paths and reduces non-essential traffic.

### 4.5 Timebox non-interactive runs (mandatory)
Never run `claude -p` without a timeout guard in restricted environments.
Use this pattern:
```bash
tmp=$(mktemp)
(
  CLAUDE_CONFIG_DIR="$PWD/.claude-run" DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \
  claude -p --no-session-persistence --permission-mode acceptEdits "<structured_prompt>" >"$tmp" 2>&1
) &
pid=$!
deadline=$((SECONDS + 30))
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
sed -n '1,200p' "$tmp"
rm -f "$tmp"
```

Treat `rc=143` as timeout termination.

### 5. Verify after implementation (mandatory)
Run verification immediately after Claude finishes:
- Diff review: confirm edits match scope.
- Build/test: run targeted tests first, then broader checks as needed.
- Regression scan: verify adjacent behavior and error handling.

If any check fails:
- Capture failure output.
- Send a focused fix prompt to Claude Code.
- Re-run the same verification set.

### 5.5 Failure triage rules (mandatory)
Classify failures before retrying:
- `Connection error` in debug log: network/API reachability issue, not code-generation quality.
- `EPERM` writing `~/.claude*`: missing writable config dir; re-run with `CLAUDE_CONFIG_DIR`.
- No output for >20s in `-p`: likely stalled retries; abort with timeout guard, then inspect `.claude-run/debug/*.txt`.

Do not loop retries without changing one of:
- network condition
- config dir and environment flags
- permission mode
- prompt size/scope

### 6. Report completion
Summarize:
- What changed.
- What was verified.
- Residual risks or unverified areas.

Never report completion without explicit verification status.

## Verification Checklist
- Scope respected.
- No silent behavior drift.
- Tests passed (or failures documented with impact).
- Follow-up actions clearly listed.

## Generic Test Guidance
When using Claude Code for any implementation task:
- Keep prompt scope to one behavior change or one defect at a time.
- Require output to include touched files and exact verification commands used.
- Run targeted checks first, then widen scope:
```bash
swift test --filter <SuiteOrTestName>
```
- Always run with timeout guards in constrained environments.
- If hang is suspected, narrow to a single test and inspect AsyncStream/Task/continuation shutdown paths.

## Validated Behavior Snapshot (2026-02-14)
- CLI version confirmed: `2.1.32`.
- Required options present in help output.
- Invalid `permission-mode` and invalid `setting-sources` fail with non-zero exit.
- In this restricted environment, `claude -p` and `claude doctor` can stall due repeated `Connection error` retries; treat as environment/network issue and use timeboxed execution.
