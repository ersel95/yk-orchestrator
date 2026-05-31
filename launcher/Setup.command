#!/usr/bin/env bash
# YK Orchestrator — Tek tıklık kurulum (Terminal'de açılır)
# .command uzantılı dosyalar Finder'da çift tıklandığında Terminal.app'te açılır.
# Terminal'in Desktop'a erişim hakkı varsa (genelde vardır) kurulum sorunsuz tamamlanır.
set -e

SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"

cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║          YK iOS Orchestrator — Kurulum                   ║
║   Bu pencereyi açık tut. Bittiğinde mesaj çıkacak.        ║
╚══════════════════════════════════════════════════════════╝
BANNER

cd "$ROOT"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

echo "→ Proje konumu: $ROOT"
echo

# 1) Python venv
if [ ! -x "$ROOT/.venv/bin/python" ]; then
  echo "→ [1/4] Python sanal ortamı oluşturuluyor"
  if command -v python3.11 >/dev/null 2>&1; then
    python3.11 -m venv "$ROOT/.venv"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m venv "$ROOT/.venv"
  else
    echo "✖ python3 bulunamadı. Önce kur: brew install python@3.11"
    read -r -p "Devam etmek için Enter…"
    exit 1
  fi
else
  echo "✓ Python venv zaten var"
fi

# 2) Backend bağımlılıkları
echo "→ [2/4] Backend bağımlılıkları yükleniyor (birkaç dakika sürebilir)"
"$ROOT/.venv/bin/python" -m pip install --upgrade pip --quiet
"$ROOT/.venv/bin/python" -m pip install -e "$ROOT/apps/api"

# 3) Frontend bağımlılıkları
echo "→ [3/4] Dashboard bağımlılıkları yükleniyor"
cd "$ROOT/apps/dashboard"
if command -v pnpm >/dev/null 2>&1; then
  pnpm install
elif command -v npm >/dev/null 2>&1; then
  npm install
else
  echo "✖ npm/pnpm bulunamadı. Node 20+ kur: brew install node"
  read -r -p "Devam etmek için Enter…"
  exit 1
fi
cd "$ROOT"

# 4) .env
echo "→ [4/4] .env dosyası kontrolü"
if [ ! -f "$ROOT/.env" ]; then
  cp "$ROOT/.env.example" "$ROOT/.env"
  echo "✓ .env oluşturuldu"
  ENV_FRESH=1
else
  echo "✓ .env zaten var"
  ENV_FRESH=0
fi

mkdir -p "$ROOT/data/chroma" "$ROOT/logs" "$ROOT/.run"

echo
echo "═════════════════════════════════════════════════"
echo "✓ Kurulum tamam"
echo "═════════════════════════════════════════════════"
echo
if [ "$ENV_FRESH" = "1" ]; then
  echo "ÖNEMLİ: .env dosyasını düzenle (Jira/Bitbucket token, repo path)"
  echo "  $ROOT/.env"
  echo
fi
echo "Sonraki adım:"
echo "  • LM Studio'yu aç, modelleri indir, Local Server'ı başlat (port 1234)"
echo "  • launcher/YK Orchestrator.app üzerine çift tıkla"
echo
osascript -e 'display notification "Kurulum tamamlandı" with title "YK Orchestrator"' || true
read -r -p "Bu pencereyi kapatmak için Enter…"
