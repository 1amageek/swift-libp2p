#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  set -- Sources
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "rg is required" >&2
  exit 2
fi

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(rg --files "$@" | rg '\.swift$' || true)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No Swift files found under: $*"
  exit 0
fi

violations=0

for file in "${files[@]}"; do
  if awk '
    BEGIN { in_deinit = 0; depth = 0; found = 0 }
    {
      line = $0
      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)

      if (!in_deinit && $0 ~ /deinit[[:space:]]*\{/) {
        in_deinit = 1
        depth = 0
      }

      if (in_deinit) {
        depth += opens - closes
        if ($0 ~ /syncShutdownGracefully[[:space:]]*\(/) {
          print FILENAME ":" NR ": syncShutdownGracefully() inside deinit"
          found = 1
        }
        if ($0 ~ /waitUntilExit[[:space:]]*\(/) {
          print FILENAME ":" NR ": waitUntilExit() inside deinit"
          found = 1
        }
        if (depth <= 0) {
          in_deinit = 0
          depth = 0
        }
      }
    }
    END { exit found ? 1 : 0 }
  ' "$file"; then
    :
  else
    violations=1
  fi
done

if [[ "$violations" -ne 0 ]]; then
  echo "Found forbidden blocking pattern inside deinit" >&2
  exit 1
fi

echo "OK: no blocking shutdown/process waits inside deinit"
