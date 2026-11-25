#!/usr/bin/env bash
#
# Build and sign the standalone MindDock.app macOS bundle into dist/MindDock.app.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/MindDock.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
EXECUTABLE_NAME="MindDock"

echo "==> Building MindDockApp (release)..."
cd "${ROOT_DIR}"
swift build -c release --disable-sandbox --product MindDockApp
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
BUILT_BINARY="${BIN_DIR}/MindDockApp"

if [[ ! -x "${BUILT_BINARY}" ]]; then
  echo "error: expected release binary not found at ${BUILT_BINARY}" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BUILT_BINARY}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"
printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>MindDock</string>
    <key>CFBundleExecutable</key>
    <string>MindDock</string>
    <key>CFBundleIdentifier</key>
    <string>com.minddock.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MindDock</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>MindDock uses the microphone strictly on demand when you trigger a spoken Drop, releasing audio hardware immediately after capture.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>MindDock uses macOS Speech Recognition on demand to transcribe spoken Drops and off-desk voice messages.</string>
</dict>
</plist>
PLIST

plutil -lint "${CONTENTS_DIR}/Info.plist"

echo "==> Signing MindDock.app (ad-hoc)..."
codesign --force --deep -s - "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

echo "==> Built standalone app bundle: ${APP_DIR}"
echo "    Launch with: open \"${APP_DIR}\""
echo "    Smoke check: \"${MACOS_DIR}/${EXECUTABLE_NAME}\" --smoke-check"
