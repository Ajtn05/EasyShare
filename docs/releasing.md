# Releasing

A release is driven by a tag. `.github/workflows/release.yml` builds both
platforms, attaches the artifacts to a GitHub Release, and writes install notes
that describe what it actually produced.

```bash
# bump the marketing version everywhere first
vim VERSION                       # e.g. 0.5.2
vim macos/project.yml             # MARKETING_VERSION on both targets
vim android/app/build.gradle.kts  # versionCode, by hand
./scripts/check-version.sh v0.5.2

git tag v0.5.2 && git push origin v0.5.2
```

`scripts/check-version.sh` runs first in both build jobs with the tag as its
argument, so a tag that disagrees with `VERSION` fails before anything builds.

## What lands on the Releases page

| Artifact | Signed | Unsigned fallback |
|---|---|---|
| `EasyShare-vX.Y.Z.dmg` | Developer ID, notarized, stapled | ad-hoc signed, quarantined by Gatekeeper |
| `easy-share-vX.Y.Z.apk` | release keystore | debug-signed apk under a `-debug-unsigned-release` name |

Both halves degrade rather than fail, but they degrade differently, and the
reason is not symmetry — it is what the platform will actually run:

- **Android:** `assembleRelease` with no keystore emits
  `app-release-unsigned.apk`, and Android cannot install an unsigned apk at
  all. So the fallback publishes the **debug** apk, which is signed with
  Android's debug key and does install. It is debuggable, and it cannot upgrade
  a release-signed install — different signing key, so the package manager
  refuses. Fine for testing, not for real distribution.
- **macOS:** a genuinely unsigned bundle will not launch on Apple Silicon at
  all, so the fallback is ad-hoc signed (`CODE_SIGN_IDENTITY="-"`). It runs,
  but it is not notarized, so Gatekeeper refuses it on first open until the
  user clears the quarantine attribute. The generated release notes say so and
  give the command.

## Secrets

None are configured yet, so today a tag produces the fallback artifacts. Adding
them upgrades the same workflow with no edits.

### Android

| Secret | Contents |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -i release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias |
| `ANDROID_KEY_PASSWORD` | key password |

The keystore is decoded to a runner temp file and `EASYSHARE_KEYSTORE` points
at it; `android/app/build.gradle.kts` creates a release signing config only
when that file exists. **Back the keystore up somewhere durable before the
first signed release.** Losing it means no existing install can ever be
upgraded — the only way out is a new `applicationId`.

### macOS

| Secret | Contents |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of a Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | its export password |
| `MACOS_TEAM_ID` | the team id |
| `AC_ISSUER_ID`, `AC_KEY_ID`, `AC_PRIVATE_KEY` | App Store Connect API key for `notarytool` |

**This Mac has no Developer ID Application certificate** — `security
find-identity -v -p codesigning` lists only an Apple Development identity,
which cannot be used for distribution outside the App Store. Creating one needs
a paid Apple Developer Program membership; then Xcode → Settings → Accounts →
Manage Certificates → **+** → Developer ID Application, and export it as `.p12`.

Until that exists, every macOS release is the ad-hoc fallback.

### Two gotchas the workflow already handles

- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` is passed to both release builds.
  Without it the Release build carries `com.apple.security.get-task-allow`, and
  notarization rejects any binary that requests it. With it, the bundles carry
  exactly the four (app) and three (extension) hand-written entitlements.
- The app and its embedded extension must be signed by one identity. That is
  what the project-level `configFiles:` in `macos/project.yml` guarantees; do
  not set signing per target.

## Packaging

`scripts/make-dmg.sh <app> <dmg>` stages the built app next to a symlink to
`/Applications` and runs `hdiutil create`. That symlink is the entire install
gesture — drag one onto the other. The script neither signs nor notarizes; the
workflow signs the app before packaging and the `.dmg` after.

## Why the install needs no extra steps

Nothing registers the Finder extension by hand. macOS registers an app's
embedded extensions through LaunchServices when the containing app is launched
from `/Applications`, and a `com.apple.share-services` extension is enabled on
registration — `pluginkit -m -p com.apple.share-services` shows it with a `+`.
There is no `pluginkit -a` step and no System Settings step in a normal
install. The manual steps needed during development exist only because a build
in DerivedData is registered from that path instead.

## Not decided yet

- Whether the `.dmg` gets a Sparkle appcast, or updates stay manual.
- Whether Android releases ever reach Play, which would add
  `:app:bundleRelease` and Play App Signing instead of a local keystore.
