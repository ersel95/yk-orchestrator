#!/usr/bin/env bash
#
# Backend (FastAPI) → PyInstaller tek-dosya binary build.
# Hedef: macOS arm64 (Apple Silicon).
#
# Çıktı: build/dist/ykorch-api
# Çalıştırma testi:
#   YKORCH_DEV=0 build/dist/ykorch-api --port 49152
#   curl http://127.0.0.1:49152/health
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_DIR="${REPO_ROOT}/apps/api"
BUILD_DIR="${REPO_ROOT}/build"
BUILD_VENV="${BUILD_DIR}/.venv-build"
DIST_DIR="${BUILD_DIR}/dist"
SPEC_FILE="${API_DIR}/build/ykorch-api.spec"

PYTHON_BIN="${PYTHON_BIN:-python3.12}"

echo "==> Repo: ${REPO_ROOT}"
echo "==> Apple Silicon target (arm64)"

# Sanity: arm64 makinede çalıştığımızı doğrula
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "HATA: arm64 binary için arm64 makinede çalıştırılmalı. Mevcut: $(uname -m)" >&2
  exit 1
fi

# Python kontrolü
if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "HATA: ${PYTHON_BIN} bulunamadı. PYTHON_BIN env ile farklı bir interpreter ver." >&2
  exit 1
fi

# Build venv
if [[ ! -d "${BUILD_VENV}" ]]; then
  echo "==> Build venv oluşturuluyor: ${BUILD_VENV}"
  "${PYTHON_BIN}" -m venv "${BUILD_VENV}"
fi

# shellcheck disable=SC1091
source "${BUILD_VENV}/bin/activate"

echo "==> Pip + bağımlılıklar güncelleniyor"
python -m pip install --upgrade pip wheel >/dev/null
python -m pip install --upgrade "pyinstaller>=6.10" >/dev/null
python -m pip install -e "${API_DIR}" >/dev/null

echo "==> Eski build artefaktları temizleniyor"
rm -rf "${BUILD_DIR}/work" "${DIST_DIR}"

echo "==> PyInstaller başlatılıyor (bu birkaç dakika sürebilir)"
pyinstaller \
  --noconfirm \
  --clean \
  --workpath "${BUILD_DIR}/work" \
  --distpath "${DIST_DIR}" \
  "${SPEC_FILE}"

BUNDLE_DIR="${DIST_DIR}/ykorch-api"
BINARY="${BUNDLE_DIR}/ykorch-api"
if [[ ! -x "${BINARY}" ]]; then
  echo "HATA: binary üretilemedi: ${BINARY}" >&2
  exit 1
fi

SIZE_MB=$(du -sm "${BUNDLE_DIR}" | awk '{print $1}')
echo ""
echo "==> Build tamamlandı (onedir)"
echo "    Bundle:   ${BUNDLE_DIR}"
echo "    Toplam:   ${SIZE_MB} MB"
echo "    Mimari:   $(lipo -archs "${BINARY}" 2>/dev/null || file "${BINARY}")"
echo "    Entries:  $(ls "${BUNDLE_DIR}" | wc -l | tr -d ' ')"

echo ""
echo "==> --version smoke test"
"${BINARY}" --version
