# Handoff

## Product scope

Easy Share has two deliberately different paths:

- **Android → Mac:** Android's built-in **Quick Share** sends to the Easy Share
  macOS menu-bar receiver. There is no Android app involved in this direction.
- **Mac → Android:** Finder → Share → Easy Share normally sends to the small
  **Easy Share Companion** on Android. A user pairs once with a six-digit
  code; subsequent sends use the paired device only while its receiver is
  enabled. Stock Quick Share discovery and QR remain in Finder as a manual,
  non-persistent fallback.

Both directions are local-network sharing. Devices need the same Wi-Fi without
client isolation; there is no cloud relay or internet route.

## Verification status — 2026-09-03

| Area | Evidence |
|---|---|
| Quick Share core | `cd macos && swift build && swift run easyshare-selftest` covers 29 checks: filename safety, framing, UKEY2/D2D crypto, QR activation, and TCP loopback transfer. |
| Signed macOS app + Finder extension | `xcodebuild -project EasyShare.xcodeproj -scheme EasyShare -configuration Debug -sdk macosx -allowProvisioningUpdates build` succeeds and signs both targets. |
| Android → Mac stock Quick Share | **Device-verified:** Samsung Galaxy S22 / Android 16 sent a photo to the Mac after the normal four-digit Quick Share verification. |
| Mac → Android stock Quick Share | **Device-verified:** QR and normal Quick Share transfer were used successfully, including a photo and a file. It remains an anonymous, local-network route. |
| Android companion | `JAVA_HOME=…openjdk@17… ./gradlew :app:testDebugUnitTest :app:assembleDebug` succeeds. The receiver, pairing, discovery, notifications, and MediaStore transfer path are implemented, but the first real companion pairing and file transfer still need device verification. |

Do not describe the companion route as device-verified until that final test is
complete.

## First companion test

1. Build the debug APK:

   ```bash
   cd android
   JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleDebug
   ```

2. Install `android/app/build/outputs/apk/debug/app-debug.apk` on the Android
   phone. Allow **Notifications** and **Nearby devices** when requested.
3. Open **Easy Share Companion**, tap **Receive from Mac**, then **Pair new
   Mac**. This opens a two-minute window; it does not show a code yet. It may
   also be toggled later from the **Receive from Mac** Quick Settings tile.
4. In Finder, select a small file and choose **Share → Easy Share**. The phone
   appears as **Android companion • Pair this Mac**. Select it and click Send.
5. Compare the six-digit code in Finder with the Android notification. Choose
   **Pair** in Finder only when they match, then choose **Approve** on Android.
6. Approve the incoming file offer on Android. It is written to `Downloads`
   only after approval.
7. Share a second file: the phone should appear first as **Paired Android
   companion** and request only an Android Accept/Decline action — no repeat
   pairing.

After a reboot or Android stopping the foreground receiver, pairing remains
saved but availability does not. Turn on **Receive from Mac** in Quick
Settings; do **not** pair again unless the certificate identity was reset (for
example, clearing the companion's app data).

## UI recommendations

### Menu-bar receiver

- Keep the macOS menu quiet: **Ready**, **Not receiving**, or an actionable
  error. Do not surface ports, certificates, or protocol phases.
- Show Android's stock Quick Share verification code and explicit Accept /
  Decline actions for every incoming offer.

### Finder extension

- Title the sheet **Send to Android**.
- List available paired companions first. A paired row is ready only when its
  live mDNS record advertises the exact certificate fingerprint stored during
  pairing; never use an old address or a display-name match.
- For a new companion, make the six-digit comparison a brief modal step with
  clear cancel behavior. It is the human authentication step, not decoration.
- Put live stock Quick Share devices and **Connect with QR Code** after
  companion rows, and never show stock Quick Share as a saved device.
- During transfer, keep Cancel available and show byte-weighted progress.
- Android keeps the receiver's availability visible through a persistent
  notification and a Quick Settings tile. By default, pairing and file offers
  have explicit notification actions. The user may opt into a floating approval
  card after granting Android's separate Display over other apps capability;
  it then appears automatically above other apps. Never auto-accept.

## Engineering constraints

- The stock Quick Share contract is **not written down here**. There is no
  `docs/protocol.md`; treat the vendored proto definitions in
  `macos/Sources/EasyShareKit/Transports/QuickShare/Protos/` (Google's
  securegcm / securemessage / offline_wire_formats set, Apache-2.0) together
  with `Wire/QuickShareFraming.swift` and the selftest's crypto and framing
  checks as the de facto reference until someone writes one. The companion
  contract, by contrast, is fully specified in
  [`companion-protocol.md`](companion-protocol.md).
- Bind a listener to port `0`, read the actual port, then advertise it.
- mDNS TXT data is hostile discovery metadata. Pair only with a code derived
  from the TLS certificate actually presented; later connections pin that exact
  certificate and never fall back to system trust.
- Treat remote names, MIME types, lengths, and metadata as hostile. Run every
  Android output filename through `storage/IncomingFilename.sanitize` before
  MediaStore receives it.
- The Finder extension is short-lived. It must not call `completeRequest`
  while it still holds a pairing or transfer connection.
- Do not add XcodeGen `info:` or `entitlements:` settings: the hand-written
  Info.plists contain the Bonjour declaration Finder needs.

## Repository layout

```
docs/HANDOFF.md                 current product state, testing, UI guidance
docs/companion-protocol.md      paired Mac → Android protocol contract
macos/Sources/EasyShareKit/     Quick Share + paired companion transports
macos/App/                      menu-bar Android Quick Share receiver
macos/ShareExtension/           Finder sender and pairing UI
android/app/                    Android companion receiver and Quick Settings tile
```
