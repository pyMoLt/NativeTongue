# NativeTongue releases

GitHub Actions runs the HexCore tests and scans for secrets and critical Swift
dependency advisories for pull requests and pushes to `main`. The signed ARM64 macOS release is built on the authorized
release Mac with full Xcode and the Metal toolchain. Use Xcode 27 for the
Core AI targets. The release Mac runs the script directly with no GitHub
Actions runner installed.

## One-time setup

- Protect `main`, release tags matching `v*` and changes to `.github/workflows/`
  and the release scripts. Require the Swift and security checks before merging.
- Set up a **Developer ID Application** signing identity in the Mac's signing
  keychain. For notarization, keep an Apple app-specific password in `pass`.
- Provide `gh` with repository access to read Actions runs and publish
  releases. If using a GitHub token, keep it in `pass` and supply it through
  `GH_TOKEN` for the release invocation. Keep the token scoped to this repo.

## Publish a release

1. Update the app version, build number and changelogs. Merge the release
   commit to `main` and check the two push workflows in **Actions**.
2. Push a version tag pointing to that commit, for example `v3.2.3`. The
   script checks that the tag matches the version inside the built app.
3. On the release Mac, run:

   ```bash
   export NATIVETONGUE_SIGN_IDENTITY='Developer ID Application: …'
   export NATIVETONGUE_NOTARY_APPLE_ID='…'
   export NATIVETONGUE_NOTARY_TEAM_ID='…'
   export NATIVETONGUE_NOTARY_PASS_ENTRY='…'
   ./scripts/release-github.sh v3.2.3
   ```

The script verifies the tag and successful GitHub checks for its exact commit.
It builds an isolated copy, signs and notarizes it, attaches Apple's ticket and
checks the result with Gatekeeper. GitHub Releases receives the final ZIP and
its SHA-256 checksum. The command requires a fresh GitHub release for the tag.
Use a new version tag for a correction.

For unattended publishing, the operator can schedule the local release agent
(`docker/scripts/github-release-agent.py native`) on the signing Mac. It starts
after the version tag is pushed and the exact commit has passed both checks.
