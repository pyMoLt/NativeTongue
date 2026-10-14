#!/bin/zsh
# Builds a Release NativeTongue.app (arm64, hardened runtime, no App Sandbox)
# into dist/. Usage: scripts/build-dist.sh [--install]
#
# Signing: NATIVETONGUE_SIGN_IDENTITY if set, otherwise the local self-signed
# "NativeTongue Local" code-signing identity (created in Keychain Access; Apple
# cannot revoke it), otherwise the first "Apple Development" identity whose
# certificate Apple has not revoked. A stable identity lets macOS keep
# Microphone/Accessibility/Input Monitoring grants across builds. Without a
# usable identity the app is ad-hoc signed.
#
# A revoked certificate still shows up as "valid" in the keychain, but after
# the next restart macOS treats the app as malware and moves it to the Bin,
# so every Apple Development candidate is checked online (OCSP) first. A
# candidate whose status cannot be confirmed (offline, OCSP error) is skipped:
# the check fails closed.
set -euo pipefail
cd "$(dirname "$0")/.."

# Prints good, revoked or unknown for the certificate with the given SHA-1.
cert_status() {
  local pem
  pem=$(mktemp -t nativetongue-cert)
  security find-certificate -a -Z -p | awk -v h="$1" '
    /^SHA-1 hash:/ { take = ($3 == h); next }
    take { print }
    take && /END CERTIFICATE/ { exit }' > "$pem"
  local result
  result=$(security verify-cert -c "$pem" -p codeSign -R ocsp -R require 2>&1 || true)
  rm -f "$pem"
  if [[ "$result" == *REVOKED* ]]; then echo revoked
  elif [[ "$result" == *"verification successful"* ]]; then echo good
  else echo unknown
  fi
}

if [[ -n "${NATIVETONGUE_SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$NATIVETONGUE_SIGN_IDENTITY"
else
  SIGN_IDENTITY=$(security find-identity -p codesigning | awk '/"NativeTongue Local"/ {print $2; exit}')
  [[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="-"
  [[ "$SIGN_IDENTITY" == "-" ]] && for candidate in $(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}'); do
    case "$(cert_status "$candidate")" in
      good) SIGN_IDENTITY="$candidate"; break ;;
      revoked) echo "Skipping revoked Apple Development certificate $candidate." ;;
      *) echo "Skipping Apple Development certificate $candidate: revocation status could not be checked online (offline or OCSP error)." ;;
    esac
  done
  [[ "$SIGN_IDENTITY" == "-" ]] && echo "No usable Apple Development identity; using ad-hoc signature."
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
# ~/Library/Application Support are used (hardened runtime stays on). Nested
# code (frameworks, plug-ins, helpers, bundles with an executable) is signed
# first and without the app's entitlements; then the app itself, not --deep.
for nested in dist/NativeTongue.app/Contents/{Frameworks,PlugIns,XPCServices,Helpers,Library/LoginItems}/*(N) \
              dist/NativeTongue.app/Contents/Resources/*.bundle(N); do
  if [[ "$nested" == *.bundle && ! -d "$nested/Contents/MacOS" ]]; then continue; fi
  if [[ "$nested" == *.bundle && -z "$(ls -A "$nested/Contents/MacOS")" ]]; then continue; fi
  codesign --force --sign "$SIGN_IDENTITY" --options runtime "$nested"
done
codesign --force --sign "$SIGN_IDENTITY" --options runtime \
  --entitlements Hex/NativeTongue-Direct.entitlements dist/NativeTongue.app
codesign --verify --deep --strict dist/NativeTongue.app
if [[ "$SIGN_IDENTITY" != "-" ]] && spctl -a -t exec dist/NativeTongue.app 2>&1 | grep -q REVOKED; then
  echo "Signing certificate is revoked; refusing to install a build macOS would quarantine." >&2
  exit 1
fi
echo "dist/NativeTongue.app ($(du -sh dist/NativeTongue.app | cut -f1)), signed with: $SIGN_IDENTITY"

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
  open "$TARGET"
fi
