# Easy Share

[![CI](../../actions/workflows/ci.yml/badge.svg?branch=main)](../../actions/workflows/ci.yml)
[![macOS release](https://img.shields.io/badge/macOS-DMG-000000?logo=apple&logoColor=white)](../../releases/latest)
[![Android companion](https://img.shields.io/badge/Android-APK-3DDC84?logo=android&logoColor=white)](../../releases/latest)
[![Security policy](https://img.shields.io/badge/Security-policy-2ea44f?logo=github&logoColor=white)](SECURITY.md)

Easy Share transfers files both ways between a Mac and Android:

- **Android → Mac:** Android's built-in Quick Share sends to the small macOS
  menu-bar receiver.
- **Mac → Android:** Finder → Share → Easy Share sends to a small, paired
  Android companion. You pair once. After that, enable its **Receive from Mac**
  Quick Settings tile whenever you want the phone to be available.

Both paths share over the local network. The two devices must use the same
Wi-Fi network, and that network must not use client isolation. The Finder
extension also keeps stock Android Quick Share, including QR, as a fallback.
That fallback cannot provide a durable recipient identity.

Read [docs/HANDOFF.md](docs/HANDOFF.md) for the verification status, the test
steps, and the intended UI.

## Install

Every tagged release carries both artifacts on the [Releases](../../releases)
page.

**macOS.** Open `EasyShare-vX.Y.Z.dmg`. Drag **EasyShare.app** onto the
**Applications** shortcut in the same window. Launch the app once. That is the
whole install.

On first launch, macOS registers the embedded Finder extension and enables it.
**Share → Easy Share** then appears in Finder. You do not need to open System
Settings, and you do not need `pluginkit`. The app is a menu-bar accessory, so
it has no Dock icon. Find it in the status bar.

> Until you have a Developer ID certificate, each released disk image is ad-hoc
> signed and not notarized. Gatekeeper refuses such an app on first open. After
> you drag the app to Applications, run
> `xattr -dr com.apple.quarantine /Applications/EasyShare.app` once.
> [docs/releasing.md](docs/releasing.md) explains what removes this step.

**Android.** Download the `.apk` from the same release. Sideload it on the
phone. On first launch, allow **Notifications** and **Nearby devices**.

## Prerequisites

### macOS side

- macOS 13 or later, and Xcode with its command line tools.
- XcodeGen: `brew install xcodegen`.
- **This repository does not contain `EasyShare.xcodeproj`.** XcodeGen
  generates it from [`macos/project.yml`](macos/project.yml). Run the command
  below after you clone the repository, and again after every change to
  `project.yml`. Always run it before `xcodebuild`:

  ```bash
  cd macos && xcodegen generate
  ```

- Signing uses your own Apple team. The repository tracks
  `macos/Signing.xcconfig`, which contains a blank `DEVELOPMENT_TEAM`. Put your
  own team in `macos/Signing.local.xcconfig`. `.gitignore` excludes that file:

  ```bash
  echo 'DEVELOPMENT_TEAM = ABCDE12345' > macos/Signing.local.xcconfig
  ```

  To find your team id:

  ```bash
  security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
  ```

  The team id is the `OU` field. The project still generates and compiles
  without this file. Only signing and running the app locally need it.

### Android side

- JDK 17. Android Studio includes one. `brew install openjdk@17` also works.
- The Android SDK, and a machine-local `android/local.properties` that gives
  the SDK location. `.gitignore` excludes that file, because it holds an
  absolute path:

  ```bash
  echo "sdk.dir=$HOME/Library/Android/sdk" > android/local.properties
  ```

  You can omit that file when your environment sets `ANDROID_HOME`. CI builds
  that way.

## Build the Mac transport

```bash
cd macos
swift build && swift run easyshare-selftest
```

The menu-bar app and the Finder extension need Xcode:

```bash
cd macos
xcodegen generate
xcodebuild -project EasyShare.xcodeproj -scheme EasyShare \
  -configuration Debug -sdk macosx -allowProvisioningUpdates \
  -derivedDataPath build build
```

Without a `DEVELOPMENT_TEAM`, Xcode signs the app "to run locally". That is an
ad-hoc signature. It is enough to build the app and to run it on your own
machine. Set your team in `macos/Signing.local.xcconfig` only when you want a
real identity.

### Run what you built

The build writes `build/Build/Products/Debug/EasyShare.app`. The app also runs
from that location, but macOS then registers the Finder extension from that
path. Move the app first, then launch it once:

```bash
cp -R build/Build/Products/Debug/EasyShare.app /Applications/
open /Applications/EasyShare.app
```

Expect three things on first launch:

1. **No Dock icon.** The app is a menu-bar accessory. Find it in the status
   bar.
2. **A local-network permission prompt.** Allow it. If you decline, the app
   cannot discover or receive anything. macOS does not ask a second time. You
   must then grant local network access under System Settings → Privacy &
   Security → Local Network.
3. **Share → Easy Share in Finder.** This needs no further setup. macOS
   registers the embedded extension on first launch and enables it.

An app that you build yourself carries no quarantine attribute. The Gatekeeper
step under [Install](#install) does not apply to it.

To package a built app the way a release does:

```bash
scripts/make-dmg.sh path/to/EasyShare.app EasyShare.dmg
```

That script does not sign or notarize the app. See
[docs/releasing.md](docs/releasing.md).

## Build the Android companion

This build needs Android Studio or JDK 17:

```bash
cd android
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testDebugUnitTest :app:assembleDebug
```

You need the `JAVA_HOME` prefix only when your default `java` is not 17. If you
do not have the SDK components for `compileSdk 35`, open `android/` in Android
Studio once. Android Studio then offers to install them.

The build writes `android/app/build/outputs/apk/debug/app-debug.apk`. Install
that file on the phone. Then allow **Notifications** and **Nearby devices**.
The pairing walkthrough is in
[docs/HANDOFF.md](docs/HANDOFF.md#first-companion-test).

## Versioning

The root [`VERSION`](VERSION) file holds the marketing version for both
platforms. Android reads that file directly. `macos/project.yml` carries the
same literal, and `scripts/check-version.sh` fails when the two disagree. CI
runs that script.

You increase the two build numbers by hand: `CURRENT_PROJECT_VERSION` and
Android's `versionCode`. They do not have to match each other.

## License

MIT. See [LICENSE](LICENSE). The vendored Quick Share `.proto` definitions
under `macos/Sources/EasyShareKit/Transports/QuickShare/Protos/` belong to
Google, under Apache-2.0, and keep their own headers. To report a
vulnerability, see [SECURITY.md](SECURITY.md).
