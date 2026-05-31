#!/usr/bin/env bash
set -euo pipefail

# YK iOS Orchestrator — Setup
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Python venv oluşturuluyor"
if [ ! -d ".venv" ]; then
  python3.11 -m venv .venv 2>/dev/null || python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

echo "→ Backend bağımlılıkları yükleniyor"
pip install --upgrade pip
pip install -e "apps/api"

echo "→ Frontend bağımlılıkları yükleniyor"
cd apps/dashboard
if command -v pnpm >/dev/null 2>&1; then
  pnpm install
elif command -v npm >/dev/null 2>&1; then
  npm install
else
  echo "✖ pnpm veya npm bulunamadı. Node.js 20+ kur."
  exit 1
fi
cd "$ROOT"

if [ ! -f ".env" ]; then
  cp .env.example .env
  echo "→ .env oluşturuldu — değerleri doldur"
fi

mkdir -p data/chroma logs

echo
echo "✓ Kurulum tamam"
echo "Sonraki adımlar:"
echo "  1) .env dosyasını düzenle (Jira/Bitbucket token, repo path, vs.)"
echo "  2) LM Studio'da Qwen2.5-72B-Instruct (MLX) modelini indir, server'ı başlat (http://127.0.0.1:1234)"
echo "  3) ./scripts/run-dev.sh ile başlat"
