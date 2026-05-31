#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/scripts/launchd/com.yk.orchestrator.morning.plist"
DEST="$HOME/Library/LaunchAgents/com.yk.orchestrator.morning.plist"

cp "$PLIST" "$DEST"
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"
echo "✓ launchd job yüklendi: $DEST"
echo "  Test: launchctl start com.yk.orchestrator.morning"
