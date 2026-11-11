#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo=pyMoLt/NativeTongue
tag=${1:-}
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: $0 vMAJOR.MINOR.PATCH" >&2; exit 2; }
: "${NATIVETONGUE_SIGN_IDENTITY:?Set the Developer ID Application identity name}"
: "${NATIVETONGUE_NOTARY_APPLE_ID:?Set the Apple ID}"
: "${NATIVETONGUE_NOTARY_TEAM_ID:?Set the Apple Team ID}"
: "${NATIVETONGUE_NOTARY_PASS_ENTRY:?Set the pass entry for the app-specific password}"
export NATIVETONGUE_NOTARY_APPLE_ID NATIVETONGUE_NOTARY_TEAM_ID NATIVETONGUE_NOTARY_PASS_ENTRY
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

git fetch https://github.com/"$repo".git refs/heads/main "refs/tags/$tag:refs/tags/$tag"
main=$(git ls-remote https://github.com/"$repo".git refs/heads/main | cut -f1)
commit=$(git rev-parse "$tag^{commit}")
git merge-base --is-ancestor "$commit" "$main"
for workflow in check.yml security.yml; do
  result=$(gh run list -R "$repo" -w "$workflow" -b main -e push -c "$commit" -L 1 \
    --json conclusion --jq '.[0].conclusion // ""')
  [[ "$result" == success ]] || { echo "Missing successful main run for $workflow ($commit)" >&2; exit 1; }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/nativetongue-release.XXXXXXXX")
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$work"' EXIT
git archive "$commit" | tar -x -C "$work"
cd "$work"
export NATIVETONGUE_PUBLIC_RELEASE=1 NATIVETONGUE_DERIVED_DATA="$work/DerivedData"
env -u GH_TOKEN -u GITHUB_TOKEN scripts/build-dist.sh
app=dist/NativeTongue.app
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$tag" == "v$version" ]] || { echo "Tag and app version differ" >&2; exit 1; }

zip="NativeTongue-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
export NATIVETONGUE_NOTARY_ARCHIVE="$work/$zip"
# Answer Apple's secure prompt directly from pass. The password never enters
# command arguments, exported variables, logs or a temporary file.
/usr/bin/expect <<'EXPECT'
set timeout 45
log_user 0
spawn xcrun notarytool submit $env(NATIVETONGUE_NOTARY_ARCHIVE) --wait --timeout 30m \
  --apple-id $env(NATIVETONGUE_NOTARY_APPLE_ID) --team-id $env(NATIVETONGUE_NOTARY_TEAM_ID)
expect {
  -glob "Password for *: " {
    if {[catch {exec pass show $env(NATIVETONGUE_NOTARY_PASS_ENTRY)} entry]} {
      puts stderr "Could not read notarization password from pass"
      exit 1
    }
    send -- "[lindex [split $entry \n] 0]\r"
    unset entry
  }
  timeout {puts stderr "Notary password prompt timed out"; exit 1}
  eof {puts stderr "Notary tool exited before authentication"; exit 1}
}
set timeout 1900
set accepted 0
expect {
  -nocase -re {status:[[:space:]]*Accepted} {set accepted 1; exp_continue -continue_timer}
  eof {}
  timeout {puts stderr "Notarization timed out"; exit 1}
}
if {!$accepted || [lindex [wait] 3] != 0} {
  puts stderr "Apple did not accept notarization"
  exit 1
}
EXPECT
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute "$app"
unlink "$zip"
ditto -c -k --keepParent "$app" "$zip"
shasum -a 256 "$zip" > "$zip.sha256"
gh release create "$tag" "$zip" "$zip.sha256" -R "$repo" --verify-tag --generate-notes
