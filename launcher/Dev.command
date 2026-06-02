#!/usr/bin/env bash
# YK Orchestrator — Lokal dev döngüsü
# Çalışan app'i kapatır, Swift'i Debug build eder, yeni .app'i açar.
# Backend: app içinden .venv/uvicorn ile CANLI kaynaktan başlar (PyInstaller rebuild YOK).
# Python değişikliği → sadece bu script'i tekrar çalıştır (app restart yeter).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="$ROOT/desktop"
DD="$DESKTOP/build/dd"
APP="$DD/Build/Products/Debug/YK Orchestrator.app"
BUILD_LOG="/tmp/ykorch-dev-build.log"

echo "→ Çalışan YK Orchestrator kapatılıyor…"
osascript -e 'tell application "YK Orchestrator" to quit' >/dev/null 2>&1 || true
pkill -x "YK Orchestrator" 2>/dev/null || true
# App SIGTERM ile sidecar'ı (venv uvicorn) kapatır; emniyet için artıkları topla
sleep 1
pkill -f "uvicorn app.main:app" 2>/dev/null || true

# Yeni .swift dosyaları .xcodeproj'a otomatik dahil olsun (XcodeGen — sources glob)
if command -v xcodegen >/dev/null 2>&1; then
  echo "→ xcodegen generate (yeni dosyalar dahil ediliyor)…"
  ( cd "$DESKTOP" && xcodegen generate >/dev/null 2>&1 ) || echo "  (xcodegen atlandı)"
fi

echo "→ Debug build…"
xcodebuild -project "$DESKTOP/YKOrchestrator.xcodeproj" \
  -scheme YKOrchestrator -configuration Debug \
  -derivedDataPath "$DD" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$BUILD_LOG" | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
rc=${PIPESTATUS[0]}

if [ "$rc" -ne 0 ]; then
  echo "✖ Build başarısız (rc=$rc). Detay: $BUILD_LOG"
  exit 1
fi
if [ ! -d "$APP" ]; then
  echo "✖ App bulunamadı: $APP"
  exit 1
fi

echo "→ Açılıyor: $APP"
open "$APP"
echo "✓ Hazır. Backend canlı kaynaktan (.venv/uvicorn) başlayacak."
