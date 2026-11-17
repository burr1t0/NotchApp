#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notch-codex-test.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
swiftc -module-cache-path "$TEMP_DIR/cache" \
  "$ROOT/Sources/NotchApp/CodexSessionReader.swift" \
  "$ROOT/Tests/CodexSessionReader/main.swift" -o "$TEMP_DIR/tests"
"$TEMP_DIR/tests" "$@"
