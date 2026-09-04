# Easy Share Companion for Android

This intentionally small app receives Finder shares from a Mac. It does not
replace Android's own Quick Share. Use stock Quick Share for Android → Mac.

Open the app once to grant notification and Nearby devices permission. Then
pair a Mac in person. After you pair, enable the **Receive from Mac** Quick
Settings tile whenever you want the phone to be available. The persistent
notification shows the receiver state. It presents every transfer for explicit
approval.

Build and test with JDK 17:

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testDebugUnitTest :app:assembleDebug
```

Read [../docs/HANDOFF.md](../docs/HANDOFF.md) and
[../docs/companion-protocol.md](../docs/companion-protocol.md) for the pairing
steps and the wire protocol.
