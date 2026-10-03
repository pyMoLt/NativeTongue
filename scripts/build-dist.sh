#!/bin/zsh
# Builds a Release NativeTongue.app (arm64, hardened runtime, no App Sandbox)
# into dist/. Usage: scripts/build-dist.sh [--install]
#
# Signing: NATIVETONGUE_SIGN_IDENTITY if set, otherwise the first
# "Apple Development" identity in the keychain (free Apple ID team). A stable
# identity lets macOS keep Microphone/Accessibility/Input Monitoring grants
# across builds. Without any identity the app is ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${NATIVETONGUE_SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$NATIVETONGUE_SIGN_IDENTITY"
else
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2; exit}')
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
    echo "No Apple Development identity found; using ad-hoc signature."
  fi
fi
DERIVED=/private/tmp/NativeTongue-Release
xcodebuild -scheme Hex -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="$DERIVED/Build/Products/Release/NativeTongue.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
rm -rf dist/NativeTongue.app && mkdir -p dist && cp -R "$APP" dist/
# Direct build: re-sign without App Sandbox so the already installed models in
# ~/Library/Application Support are used (hardened runtime stays on).
codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime \
  --entitlements Hex/NativeTongue-Direct.entitlements dist/NativeTongue.app
codesign --verify --deep --strict dist/NativeTongue.app
echo "dist/NativeTongue.app ($(du -sh dist/NativeTongue.app | cut -f1)), signed with: $SIGN_IDENTITY"

# --install: replace /Applications/NativeTongue.app (quits the running app first).
if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application "NativeTongue" to quit' >/dev/null 2>&1 || true
  for _ in {1..10}; do pgrep -f "/Applications/NativeTongue.app" >/dev/null || break; sleep 1; done
  rm -rf /Applications/NativeTongue.app && cp -R dist/NativeTongue.app /Applications/
  codesign --verify --deep --strict /Applications/NativeTongue.app && echo "Installed to /Applications"
  open /Applications/NativeTongue.app
fi
