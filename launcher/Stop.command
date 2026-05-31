#!/usr/bin/env bash
# YK Orchestrator — durdurucu (Terminal versiyonu)
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"
RUN="$ROOT/.run"

stop_one() {
  local name="$1"; local pidfile="$2"; local port="$3"
  if [ -f "$pidfile" ]; then
    local pid; pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
  lsof -ti :"$port" 2>/dev/null | xargs -r kill 2>/dev/null || true
  echo "✓ $name durduruldu"
}

stop_one Backend "$RUN/api.pid" 8765
stop_one Dashboard "$RUN/dashboard.pid" 3000
sleep 1
