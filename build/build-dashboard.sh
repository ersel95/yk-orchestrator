#!/usr/bin/env bash
#
# Dashboard (Next.js) → static export build.
# Çıktı: build/dist/dashboard/ (.app içine Contents/Resources/dashboard olarak gömülecek)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DASHBOARD_DIR="${REPO_ROOT}/apps/dashboard"
BUILD_DIR="${REPO_ROOT}/build"
DIST_DIR="${BUILD_DIR}/dist/dashboard"

echo "==> Repo:      ${REPO_ROOT}"
echo "==> Dashboard: ${DASHBOARD_DIR}"

if ! command -v npm >/dev/null 2>&1; then
  echo "HATA: npm bulunamadı. Node.js 20+ kur." >&2
  exit 1
fi

cd "${DASHBOARD_DIR}"

# Temiz state
if [[ "${CLEAN:-0}" == "1" ]] || [[ ! -d node_modules ]]; then
  echo "==> npm ci"
  npm ci --no-audit --no-fund
fi

echo "==> Önceki çıktıları temizliyorum"
rm -rf "${DASHBOARD_DIR}/.next" "${DASHBOARD_DIR}/out" "${DIST_DIR}"

echo "==> Next.js static export build"
npx --no-install next build

if [[ ! -d "${DASHBOARD_DIR}/out" ]]; then
  echo "HATA: out/ üretilemedi. next.config.mjs'te output: 'export' var mı?" >&2
  exit 1
fi

echo "==> Çıktı bundle dizinine kopyalanıyor"
mkdir -p "$(dirname "${DIST_DIR}")"
cp -R "${DASHBOARD_DIR}/out" "${DIST_DIR}"

# Smoke check
test -f "${DIST_DIR}/index.html" || { echo "HATA: index.html eksik"; exit 1; }
test -d "${DIST_DIR}/_next/static" || { echo "HATA: _next/static eksik"; exit 1; }

SIZE_MB=$(du -sm "${DIST_DIR}" | awk '{print $1}')
ENTRIES=$(find "${DIST_DIR}" -name "index.html" | wc -l | tr -d ' ')

echo ""
echo "==> Dashboard build tamamlandı"
echo "    Dizin:      ${DIST_DIR}"
echo "    Boyut:      ${SIZE_MB} MB"
echo "    Sayfa adedi: ${ENTRIES}"
