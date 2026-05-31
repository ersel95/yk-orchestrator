#!/usr/bin/env bash
#
# CI release script — build, Developer-ID sign, notarize, staple, DMG paketle.
# Tag push'ta `.github/workflows/release.yml` tarafından çağrılır.
#
# Gerekli ENV:
#   SIGNING_IDENTITY   "Developer ID Application: Ersel Tarhan (XZAJKFLEF8)"
#   ASC_KEY_PATH       App Store Connect API .p8 path'i
#   ASC_KEY_ID         ASC API Key ID (10 char)
#   ASC_ISSUER_ID      ASC Issuer ID (UUID)
#   SU_PUBLIC_ED_KEY   Sparkle EdDSA public key (Info.plist'e gömülecek)
#
# Usage: scripts/release.sh <version>
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>}"
: "${SIGNING_IDENTITY:?set SIGNING_IDENTITY}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${SU_PUBLIC_ED_KEY:?set SU_PUBLIC_ED_KEY}"

APP_NAME="YK Orchestrator"
APP_BASENAME="YKOrchestrator"
DIST="$(pwd)/dist"
RELEASE_DIR="$(pwd)/build/release"
EXPORT_DIR="${RELEASE_DIR}/export"
APP="${EXPORT_DIR}/${APP_NAME}.app"
DMG="${DIST}/${APP_BASENAME}-${VERSION}.dmg"

rm -rf "${DIST}" "${RELEASE_DIR}"
mkdir -p "${DIST}" "${RELEASE_DIR}"

# 1) Backend (PyInstaller onedir) + Dashboard (Next.js static export) build
echo "→ Backend build"
bash build/build-backend.sh
echo ""
echo "→ Dashboard build"
bash build/build-dashboard.sh

# 2) Resources hazırla — desktop/YKOrchestrator/Resources/{backend,dashboard}
echo ""
echo "→ Resources hazırlanıyor"
RES_SRC="desktop/YKOrchestrator/Resources"
rm -rf "${RES_SRC}/backend" "${RES_SRC}/dashboard"
cp -R build/dist/ykorch-api "${RES_SRC}/backend"
cp -R build/dist/dashboard  "${RES_SRC}/dashboard"

# 3) project.yml içine SUPublicEDKey'i CI'dan inject et (Info.plist'e gidecek).
#    project.yml'deki placeholder gerçek değerle override edilir; xcodegen
#    Info.plist'i her seferinde yeniden üretiyor → kalıcı kirlilik yok.
echo ""
echo "→ project.yml SUPublicEDKey + SUFeedURL inject"
PROJYAML="desktop/project.yml"
REPO_SLUG="${GITHUB_REPOSITORY:-ersel95/yk-orchestrator}"
FEED_URL="https://raw.githubusercontent.com/${REPO_SLUG}/main/appcast.xml"
# macOS sed -i in-place backup gerek; portable awk fallback
python3 - <<PY
import re, pathlib
p = pathlib.Path("${PROJYAML}")
text = p.read_text()
text = re.sub(r'SUPublicEDKey:\s*".*?"', f'SUPublicEDKey: "${SU_PUBLIC_ED_KEY}"', text)
text = re.sub(r'SUFeedURL:\s*\S+', f'SUFeedURL: ${FEED_URL}', text)
p.write_text(text)
print("project.yml updated:")
print("  SUPublicEDKey  ← ${SU_PUBLIC_ED_KEY}")
print("  SUFeedURL      ← ${FEED_URL}")
PY

# 4) xcodegen regenerate (project.yml değişti)
echo ""
echo "→ xcodegen"
( cd desktop && xcodegen generate )

# 5) Archive (Release) — ARCHIVE'da Resources, Frameworks ve binary üretilir
echo ""
echo "→ xcodebuild archive"
ARCHIVE="${RELEASE_DIR}/YKOrchestrator.xcarchive"
rm -rf "${ARCHIVE}"
xcodebuild \
  -project desktop/YKOrchestrator.xcodeproj \
  -scheme YKOrchestrator \
  -configuration Release \
  -archivePath "${ARCHIVE}" \
  -derivedDataPath build/derived \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
  DEVELOPMENT_TEAM=XZAJKFLEF8 \
  archive | tail -10

# 6) Export — Developer ID method (notarize için zorunlu)
echo ""
echo "→ xcodebuild -exportArchive"
EXPORT_OPTS="${RELEASE_DIR}/ExportOptions.plist"
cat > "${EXPORT_OPTS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>XZAJKFLEF8</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${SIGNING_IDENTITY}</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTS}" | tail -5

if [[ ! -d "${APP}" ]]; then
  echo "HATA: ${APP} üretilemedi" >&2
  exit 1
fi

# 7) Resources/backend ve Resources/dashboard'u .app içine kopyala
#    (xcodegen folder reference olarak ekliyor ama xcodebuild içeriği copy etmiyor)
echo ""
echo "→ Backend + Dashboard .app içine kopyalanıyor"
APP_RES="${APP}/Contents/Resources"
rm -rf "${APP_RES}/backend" "${APP_RES}/dashboard"
cp -R "${RES_SRC}/backend"   "${APP_RES}/backend"
cp -R "${RES_SRC}/dashboard" "${APP_RES}/dashboard"

# 8) Inside-out Developer-ID sign
echo ""
echo "→ Code sign (inside-out, hardened runtime)"
ENTITLEMENTS="desktop/YKOrchestrator/YKOrchestrator.entitlements"

# Backend Mach-O alt dosyaları
find "${APP_RES}/backend" \( -name "*.so" -o -name "*.dylib" \) -type f -print0 | \
  xargs -0 -I{} codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" --sign "${SIGNING_IDENTITY}" {} 2>/dev/null || true
codesign --force --options runtime --timestamp \
  --entitlements "${ENTITLEMENTS}" --sign "${SIGNING_IDENTITY}" \
  "${APP_RES}/backend/ykorch-api"

# Sparkle.framework içeride sealed olmalı (XPC services dahil) — outer sealing'den ÖNCE
SPV="${APP}/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "${SPV}" ]]; then
  for xpc in "${SPV}/XPCServices/Installer.xpc" "${SPV}/XPCServices/Downloader.xpc"; do
    [[ -e "$xpc" ]] && codesign --force --options runtime --timestamp \
      --preserve-metadata=entitlements,requirements,flags \
      --sign "${SIGNING_IDENTITY}" "$xpc"
  done
  [[ -e "${SPV}/Autoupdate" ]] && codesign --force --options runtime --timestamp \
    --sign "${SIGNING_IDENTITY}" "${SPV}/Autoupdate"
  [[ -e "${SPV}/Updater.app" ]] && codesign --force --options runtime --timestamp \
    --sign "${SIGNING_IDENTITY}" "${SPV}/Updater.app"
  codesign --force --options runtime --timestamp \
    --sign "${SIGNING_IDENTITY}" "${APP}/Contents/Frameworks/Sparkle.framework"
fi

# Outer app sealing (artık tüm nested executable'lar imzalı)
codesign --force --options runtime --timestamp \
  --identifier "com.yapikredi.ykorchestrator" \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${SIGNING_IDENTITY}" "${APP}"

codesign --verify --deep --strict --verbose=2 "${APP}" 2>&1 | tail -5

# 9) Notarize + staple
echo ""
echo "→ Notarize app"
ZIP="${RELEASE_DIR}/${APP_BASENAME}.zip"
ditto -c -k --keepParent "${APP}" "${ZIP}"
xcrun notarytool submit "${ZIP}" \
  --key "${ASC_KEY_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" --wait
xcrun stapler staple "${APP}"
rm -f "${ZIP}"

# 10) DMG paketle (drag-to-install layout)
echo ""
echo "→ DMG"
STAGE="$(mktemp -d)/${APP_NAME}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" \
  -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGE}"

# 11) DMG imzala + notarize + staple
codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG}"
xcrun notarytool submit "${DMG}" \
  --key "${ASC_KEY_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" --wait
xcrun stapler staple "${DMG}"

echo ""
echo "✓ ${DMG}"
shasum -a 256 "${DMG}"
