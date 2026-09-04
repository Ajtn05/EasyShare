# AGENTS.md

Start with `docs/HANDOFF.md`. It is the source of truth for current scope,
device-test status, and the intended user experience.

## What this is

A macOS bridge with two deliberately separate receiving paths:

```
docs/HANDOFF.md                 scope, verification, UI guidance, and test steps
docs/companion-protocol.md       pinned, paired Mac-to-Android companion contract
macos/                          SwiftPM transport plus App and Finder extension
android/                        minimal paired Android receiver
```

The menu-bar app receives Android → Mac through stock Quick Share. The Finder
extension sends Mac → Android through the paired Android companion. Keep both
directions and keep their protocols isolated.

## Rules

- Preserve stock Quick Share's UKEY2/D2D encryption, QR token matching, and
  safe-disconnect exchange. Never weaken those to diagnose interoperability.
- `docs/companion-protocol.md` is the companion contract. A paired Mac pins
  exactly one Android certificate and sends its stored token only over that
  pinned TLS connection. No system-trust fallback.
- Everything from a peer is hostile: sanitize filenames before filesystem use,
  cap advertised sizes/counts, and normalize peer labels before displaying them.
- Bind to port 0 and advertise only after the listener is ready.
- The Finder extension is short-lived. It owns the security-scoped source URLs
  until the transfer reaches a terminal state; do not finish the request early.
- Keep `Info.plist` and entitlement files hand-written. XcodeGen `info:` or
  `entitlements:` fields overwrite them with stubs and can silently break
  Bonjour or extension registration.

## Verification

```bash
cd macos && swift build && swift run easyshare-selftest
xcodebuild -project EasyShare.xcodeproj -scheme EasyShare \\
  -configuration Debug -sdk macosx -allowProvisioningUpdates build
```

The first verifies pure transport behavior; the second compiles/signs the app
and embedded Finder extension. Physical Android → Mac transfer is verified;
Mac → Android still needs a final device run before claiming interoperability.
