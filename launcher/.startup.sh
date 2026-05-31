#!/usr/bin/env bash
# YK Orchestrator — gerçek başlatma script'i
# Bu Start.command veya .app içinden Terminal üzerinden çağrılır.
# Terminal'in Desktop yetkisi olduğu için TCC engeline takılmaz.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"
LOGS="$ROOT/logs"
RUN="$ROOT/.run"
mkdir -p "$LOGS" "$RUN"

API_PORT="${API_PORT:-8765}"
DASHBOARD_PORT="${DASHBOARD_PORT:-3000}"
DASHBOARD_URL="http://127.0.0.1:${DASHBOARD_PORT}"
API_URL="http://127.0.0.1:${API_PORT}/health"

PID_API="$RUN/api.pid"
PID_DASH="$RUN/dashboard.pid"
VENV_PY="$ROOT/.venv/bin/python"
VENV_UV="$ROOT/.venv/bin/uvicorn"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

is_alive()       { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
healthy_api()    { curl -fsS --max-time 2 "$API_URL"       >/dev/null 2>&1; }
healthy_dash()   { curl -fsS --max-time 2 "$DASHBOARD_URL" >/dev/null 2>&1; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          YK iOS Orchestrator — Başlatılıyor              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "→ Proje: $ROOT"

# Eksik kurulum?
missing=()
[ -x "$VENV_PY" ] || missing+=("Python venv")
[ -d "$ROOT/apps/dashboard/node_modules" ] || missing+=("Node modules")
[ -f "$ROOT/.env" ] || missing+=(".env")
if [ ${#missing[@]} -gt 0 ]; then
  echo "✖ Eksik: ${missing[*]}"
  echo "  Önce launcher/Setup.command'i çalıştır."
  read -r -p "Kapatmak için Enter…"
  exit 1
fi

# Zaten ayakta mı?
if healthy_api && healthy_dash; then
  echo "✓ Zaten çalışıyor — tarayıcı açılıyor"
  open "$DASHBOARD_URL"
  exit 0
fi

# Backend başlat
if ! (is_alive "$PID_API" && healthy_api); then
  echo "→ Backend başlatılıyor (port $API_PORT)"
  cd "$ROOT/apps/api"
  nohup "$VENV_UV" app.main:app --host 127.0.0.1 --port "$API_PORT" \
    >>"$LOGS/api.log" 2>>"$LOGS/api.err.log" </dev/null &
  echo $! > "$PID_API"
  cd "$ROOT"
fi

# Frontend başlat
if ! (is_alive "$PID_DASH" && healthy_dash); then
  echo "→ Dashboard başlatılıyor (port $DASHBOARD_PORT)"
  cd "$ROOT/apps/dashboard"
  # Production build varsa onu kullan, yoksa dev mode
  if [ -f ".next/BUILD_ID" ]; then
    nohup npm run start >>"$LOGS/dashboard.log" 2>>"$LOGS/dashboard.err.log" </dev/null &
  else
    nohup npm run dev   >>"$LOGS/dashboard.log" 2>>"$LOGS/dashboard.err.log" </dev/null &
  fi
  echo $! > "$PID_DASH"
  cd "$ROOT"
fi

# Hazır mı?
echo "→ Backend hazır olması bekleniyor…"
for i in {1..45}; do
  if healthy_api; then echo "✓ Backend hazır"; break; fi
  sleep 1
  [ "$i" = "45" ] && { echo "✖ Backend 45sn'de yanıt vermedi. Detay: $LOGS/api.err.log"; tail -20 "$LOGS/api.err.log"; read -r -p "Enter…"; exit 1; }
done

echo "→ Dashboard hazır olması bekleniyor (ilk açılışta 30-60 sn)…"
for i in {1..120}; do
  if healthy_dash; then echo "✓ Dashboard hazır"; break; fi
  sleep 1
  [ "$i" = "120" ] && { echo "✖ Dashboard 120sn'de yanıt vermedi. Detay: $LOGS/dashboard.err.log"; tail -20 "$LOGS/dashboard.err.log"; read -r -p "Enter…"; exit 1; }
done

echo "→ Tarayıcı açılıyor: $DASHBOARD_URL"
open "$DASHBOARD_URL"
notify "YK Orchestrator" "Dashboard açıldı"
echo
echo "Servisler arka planda çalışıyor. Bu pencereyi kapatabilirsin."
echo "Durdurmak için: launcher/Stop.app (veya Stop.command)"
sleep 2
