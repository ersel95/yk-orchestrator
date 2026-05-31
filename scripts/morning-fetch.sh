#!/usr/bin/env bash
# Sabah otomatik tetik — launchd tarafından çalıştırılır.
# Backend'in çalışıyor olması lazım (run-dev.sh ile veya manuel).
set -euo pipefail

API_PORT="${API_PORT:-8765}"

# Backend ayakta mı?
if ! curl -fsS "http://127.0.0.1:${API_PORT}/health" >/dev/null; then
  osascript -e 'display notification "Backend kapalı, daily fetch yapılamadı" with title "YK Orchestrator"' || true
  exit 1
fi

# Standup üret
TODAY="$(date +%F)"
RES=$(curl -fsS -X POST "http://127.0.0.1:${API_PORT}/api/standup/generate" \
  -H "Content-Type: application/json" \
  -d "{\"for_date\":\"${TODAY}\",\"blockers\":\"\"}")

osascript -e "display notification \"Daily hazır — dashboard'ta kontrol et\" with title \"YK Orchestrator\"" || true
echo "$RES" | head -c 200
