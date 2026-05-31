#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source .venv/bin/activate

API_PORT="${API_PORT:-8765}"
DASHBOARD_PORT="${DASHBOARD_PORT:-3000}"

cleanup() {
  trap - INT TERM
  echo
  echo "→ Kapatılıyor"
  kill 0 2>/dev/null || true
}
trap cleanup INT TERM

echo "→ Backend (API) başlıyor: http://127.0.0.1:${API_PORT}"
(
  cd apps/api
  exec uvicorn app.main:app --host 127.0.0.1 --port "${API_PORT}" --reload
) &

echo "→ Frontend (dashboard) başlıyor: http://127.0.0.1:${DASHBOARD_PORT}"
(
  cd apps/dashboard
  if command -v pnpm >/dev/null 2>&1; then
    exec pnpm dev
  else
    exec npm run dev
  fi
) &

wait
