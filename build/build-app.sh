#!/usr/bin/env bash
#
# End-to-end .app + .dmg build pipeline.
#
# Adımlar (v0.9.0+ tam native UI, dashboard yok):
#   1) build-backend.sh → PyInstaller onedir
#   2) Resources kopyala → desktop/YKOrchestrator/Resources/backend
#   3) xcodebuild archive → Release .app (SwiftUI native UI)
#   4) Code sign (Developer ID Application) + entitlements
#   5) (opsiyonel) Notarize + staple
#   6) hdiutil ile .dmg üret + imza + (notarize)
#
# ENV gereksinimleri (notarize için):
#   SIGNING_IDENTITY="Developer ID Application: Ersel Tarhan (XZAJKFLEF8)"
#   TEAM_ID="XZAJKFLEF8"
#   NOTARYTOOL_PROFILE="ykorch"   # `xcrun notarytool store-credentials ykorch` ile önceden kurulmalı
#
# SKIP flag'leri (debug için):
#   SKIP_BACKEND=1, SKIP_NOTARIZE=1, SKIP_DMG=1
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP_DIR="${REPO_ROOT}/desktop"
BUILD_DIR="${REPO_ROOT}/build"
DIST_DIR="${BUILD_DIR}/dist"
RELEASE_DIR="${BUILD_DIR}/release"
ARCHIVE_PATH="${RELEASE_DIR}/YKOrchestrator.xcarchive"
EXPORT_PATH="${RELEASE_DIR}/export"
APP_NAME="YK Orchestrator"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"

# Sürüm: project.yml içinden çek
VERSION="${VERSION:-$(awk -F': *' '/MARKETING_VERSION:/{gsub(/"/,"",$2);print $2;exit}' "${DESKTOP_DIR}/project.yml")}"
VERSION="${VERSION:-0.1.0}"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Ersel Tarhan (XZAJKFLEF8)}"
TEAM_ID="${TEAM_ID:-XZAJKFLEF8}"
BUNDLE_ID="${BUNDLE_ID:-com.yapikredi.ykorchestrator}"

DMG_NAME="YKOrchestrator-${VERSION}.dmg"
DMG_PATH="${RELEASE_DIR}/${DMG_NAME}"

echo "==> Repo:     ${REPO_ROOT}"
echo "==> Version:  ${VERSION}"
echo "==> Identity: ${SIGNING_IDENTITY}"
echo ""

mkdir -p "${RELEASE_DIR}"

# ---------------------------------------------------------------------------
# 1) Backend
# ---------------------------------------------------------------------------
if [[ "${SKIP_BACKEND:-0}" != "1" ]]; then
  echo "==> [1/6] Backend (PyInstaller onedir)"
  bash "${BUILD_DIR}/build-backend.sh"
else
  echo "==> [1/6] Backend SKIPPED"
fi

# ---------------------------------------------------------------------------
# 2) Resources kopyala (v0.9.0+ dashboard yok — UI native Swift)
# ---------------------------------------------------------------------------
echo ""
echo "==> [2/6] Resources hazırlanıyor"
RESOURCES_DIR="${DESKTOP_DIR}/YKOrchestrator/Resources"
rm -rf "${RESOURCES_DIR}/backend"
mkdir -p "${RESOURCES_DIR}"

cp -R "${DIST_DIR}/ykorch-api" "${RESOURCES_DIR}/backend"
echo "    Backend:   $(du -sm "${RESOURCES_DIR}/backend" | awk '{print $1}') MB"

# project.yml mevcut Resources/ klasörünü zaten resource olarak işliyor
( cd "${DESKTOP_DIR}" && xcodegen generate >/dev/null )

# ---------------------------------------------------------------------------
# 3) Archive + export
# ---------------------------------------------------------------------------
echo ""
echo "==> [3/6] Xcode archive (Release)"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}"

xcodebuild \
  -project "${DESKTOP_DIR}/YKOrchestrator.xcodeproj" \
  -scheme YKOrchestrator \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -derivedDataPath "${BUILD_DIR}/derived" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  archive | tail -10

# Export options
EXPORT_OPTS="${RELEASE_DIR}/ExportOptions.plist"
cat > "${EXPORT_OPTS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${SIGNING_IDENTITY}</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTS}" | tail -5

if [[ ! -d "${APP_PATH}" ]]; then
  echo "HATA: ${APP_PATH} üretilemedi" >&2
  exit 1
fi

# Resources/backend'i .app/Contents/Resources/'a kopyala.
# xcodegen folder reference olarak ekliyor ama xcodebuild recursive kopyalamıyor;
# codesign aşamasından ÖNCE manuel kopya en garantili yol.
APP_RES_DIR="${APP_PATH}/Contents/Resources"
mkdir -p "${APP_RES_DIR}"
rm -rf "${APP_RES_DIR}/backend"
cp -R "${DESKTOP_DIR}/YKOrchestrator/Resources/backend" "${APP_RES_DIR}/backend"

APP_SIZE=$(du -sm "${APP_PATH}" | awk '{print $1}')
echo "    App:       ${APP_PATH}"
echo "    Boyut:     ${APP_SIZE} MB (backend dahil)"

# ---------------------------------------------------------------------------
# 4) Code sign (deep, hardened runtime)
# ---------------------------------------------------------------------------
echo ""
echo "==> [4/6] Code sign (deep, hardened runtime)"
ENTITLEMENTS="${DESKTOP_DIR}/YKOrchestrator/YKOrchestrator.entitlements"

# Önce iç binary: ykorch-api ve PyInstaller'ın gömdüğü tüm .so / .dylib'leri
# (PyInstaller bootloader bunları kendi imzalamış olabilir ama Apple Developer ID
# olarak yeniden imzalamak zorundayız.)
BACKEND_DIR="${APP_PATH}/Contents/Resources/backend"
if [[ -d "${BACKEND_DIR}" ]]; then
  # Tüm Mach-O dosyalarını bul, derinden imzala (yapraktan köke doğru)
  find "${BACKEND_DIR}" \( -name "*.so" -o -name "*.dylib" \) -type f \
    -exec codesign --force --sign "${SIGNING_IDENTITY}" --timestamp \
      --options runtime --entitlements "${ENTITLEMENTS}" {} \; >/dev/null

  # Ana binary
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp \
    --options runtime --entitlements "${ENTITLEMENTS}" \
    "${BACKEND_DIR}/ykorch-api"
fi

# Sparkle framework + helpers
SPARKLE_FW="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${SPARKLE_FW}" ]]; then
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp --options runtime \
    "${SPARKLE_FW}/Versions/B/Autoupdate" 2>/dev/null || true
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp --options runtime \
    "${SPARKLE_FW}/Versions/B/Updater.app" 2>/dev/null || true
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp --options runtime \
    "${SPARKLE_FW}/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp --options runtime \
    "${SPARKLE_FW}/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp --options runtime \
    "${SPARKLE_FW}"
fi

# Son olarak ana .app — deep ile alt seviye doğrulamayı koruyalım
codesign --force --deep --sign "${SIGNING_IDENTITY}" --timestamp \
  --options runtime --entitlements "${ENTITLEMENTS}" "${APP_PATH}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1 | tail -5

# ---------------------------------------------------------------------------
# 5) Notarize + staple (opsiyonel)
# ---------------------------------------------------------------------------
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo ""
  echo "==> [5/6] Notarize"
  if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
    echo "    NOTARYTOOL_PROFILE env tanımlı değil → SKIP"
    echo "    Tek seferlik kurulum:"
    echo "      xcrun notarytool store-credentials ykorch \\"
    echo "        --apple-id you@example.com --team-id ${TEAM_ID} \\"
    echo "        --password <app-specific-password>"
  else
    NOTARIZE_ZIP="${RELEASE_DIR}/YKOrchestrator-notarize.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${NOTARIZE_ZIP}"
    xcrun notarytool submit "${NOTARIZE_ZIP}" \
      --keychain-profile "${NOTARYTOOL_PROFILE}" --wait
    xcrun stapler staple "${APP_PATH}"
    rm -f "${NOTARIZE_ZIP}"
  fi
else
  echo "==> [5/6] Notarize SKIPPED"
fi

# ---------------------------------------------------------------------------
# 6) DMG
# ---------------------------------------------------------------------------
if [[ "${SKIP_DMG:-0}" != "1" ]]; then
  echo ""
  echo "==> [6/6] DMG paketleniyor"
  rm -f "${DMG_PATH}"

  # Geçici staging klasörü: .app + Applications shortcut
  STAGE="${RELEASE_DIR}/dmg-stage"
  rm -rf "${STAGE}"
  mkdir -p "${STAGE}"
  cp -R "${APP_PATH}" "${STAGE}/"
  ln -s "/Applications" "${STAGE}/Applications"

  hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGE}" \
    -ov -format UDZO \
    -fs HFS+ \
    "${DMG_PATH}" >/dev/null

  rm -rf "${STAGE}"

  # DMG'yi imzala
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"

  if [[ "${SKIP_NOTARIZE:-0}" != "1" ]] && [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    xcrun notarytool submit "${DMG_PATH}" \
      --keychain-profile "${NOTARYTOOL_PROFILE}" --wait
    xcrun stapler staple "${DMG_PATH}"
  fi

  DMG_MB=$(du -m "${DMG_PATH}" | awk '{print $1}')
  echo "    DMG:       ${DMG_PATH}"
  echo "    Boyut:     ${DMG_MB} MB"
else
  echo "==> [6/6] DMG SKIPPED"
fi

echo ""
echo "==> Tamamlandı"
echo "    .app: ${APP_PATH}"
[[ -f "${DMG_PATH}" ]] && echo "    .dmg: ${DMG_PATH}"
