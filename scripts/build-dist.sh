#!/bin/zsh
# Builds a Release NativeTongue.app (arm64, hardened runtime, no App Sandbox)
# into dist/. Usage: scripts/build-dist.sh [--install]
#
# Signing: Ad-hoc signed ("-") by default so anyone can build and run without
# an Apple Developer account. Set NATIVETONGUE_SIGN_IDENTITY to use a custom
# code-signing identity if desired.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${NATIVETONGUE_SIGN_IDENTITY:--}"
sign_options=(--options runtime)
package_options=()
if [[ "${NATIVETONGUE_PUBLIC_RELEASE:-0}" == 1 ]]; then
  [[ "$SIGN_IDENTITY" == "Developer ID Application: "* ]] || {
    echo "Public releases require an explicit Developer ID Application identity." >&2
    exit 1
  }
  sign_options+=(--timestamp)
  package_options+=(-onlyUsePackageVersionsFromResolvedFile)
fi
DERIVED=${NATIVETONGUE_DERIVED_DATA:-/private/tmp/NativeTongue-Release}
xcodebuild -scheme Hex -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" "${package_options[@]}" -skipMacroValidation -skipPackagePluginValidation \
  PRODUCT_BUNDLE_IDENTIFIER=com.pymolt.NativeTongue \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="$DERIVED/Build/Products/Release/NativeTongue.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
rm -rf dist/NativeTongue.app && mkdir -p dist && cp -R "$APP" dist/
# Direct build: re-sign without App Sandbox so the already installed models in
# ~/Library/Application Support are used (hardened runtime stays on). Nested
# code (frameworks, plug-ins, helpers, bundles with an executable) is signed
# first and without the app's entitlements; then the app itself, and verified.
for nested in dist/NativeTongue.app/Contents/{Frameworks,PlugIns,XPCServices,Helpers,Library/LoginItems}/*(N) \
              dist/NativeTongue.app/Contents/Resources/*.bundle(N); do
  if [[ "$nested" == *.bundle && ! -d "$nested/Contents/MacOS" ]]; then continue; fi
  if [[ "$nested" == *.bundle && -z "$(ls -A "$nested/Contents/MacOS")" ]]; then continue; fi
  codesign --force --sign "$SIGN_IDENTITY" "${sign_options[@]}" "$nested"
done
codesign --force --deep --sign "$SIGN_IDENTITY" "${sign_options[@]}" \
  --entitlements Hex/NativeTongue-Direct.entitlements dist/NativeTongue.app
codesign --verify --deep --strict dist/NativeTongue.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/NativeTongue.app/Contents/Info.plist 2>/dev/null || echo "3.2.2")
ZIP_NAME="NativeTongue-${VERSION}-macos-arm64.zip"
rm -f "dist/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent dist/NativeTongue.app "dist/$ZIP_NAME"
if [[ -d ../releases ]]; then
  rm -rf ../releases/NativeTongue.app "../releases/$ZIP_NAME"
  cp -R dist/NativeTongue.app ../releases/NativeTongue.app
  cp "dist/$ZIP_NAME" "../releases/$ZIP_NAME"
fi
echo "dist/NativeTongue.app ($(du -sh dist/NativeTongue.app | cut -f1)), signed with: $SIGN_IDENTITY"
echo "dist/$ZIP_NAME ($(du -sh "dist/$ZIP_NAME" | cut -f1))"

# --install: replace /Applications/NativeTongue.app (quits the running app first).
# The new copy is verified next to the old one before it replaces it; the old
# app is only removed after the swap succeeded.
if [[ "${1:-}" == "--install" ]]; then
  TARGET=/Applications/NativeTongue.app
  STAGED=/Applications/.NativeTongue.app.new
  rm -rf "$STAGED"
  cp -R dist/NativeTongue.app "$STAGED"
  codesign --verify --deep --strict "$STAGED"
  osascript -e 'tell application "NativeTongue" to quit' >/dev/null 2>&1 || true
  for _ in {1..10}; do pgrep -f "$TARGET/Contents/MacOS/" >/dev/null || break; sleep 1; done
  if pgrep -f "$TARGET/Contents/MacOS/" >/dev/null; then
    rm -rf "$STAGED"
    echo "NativeTongue is still running; quit it and run the install again. The installed app was not changed." >&2
    exit 1
  fi
  if [[ -d "$TARGET" ]]; then
    rm -rf "$TARGET.old"
    mv "$TARGET" "$TARGET.old"
  fi
  if mv "$STAGED" "$TARGET"; then
    rm -rf "$TARGET.old"
  else
    [[ -d "$TARGET.old" ]] && mv "$TARGET.old" "$TARGET"
    echo "Install failed; the previous app was restored." >&2
    exit 1
  fi
  codesign --verify --deep --strict "$TARGET" && echo "Installed to /Applications"
  [[ "${NO_OPEN:-0}" == "1" ]] || open "$TARGET"
fi
