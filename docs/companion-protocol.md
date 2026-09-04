# Companion protocol

This protocol is only for **Mac → Android** after the user pairs the Android
Easy Share Companion with the Mac once. Android → Mac continues to use stock
Android Quick Share and does not use this protocol.

## Discovery

The companion advertises `_easyshare-companion._tcp` by mDNS only while its
user-enabled receiver is active. Its TXT record contains:

| Key | Value |
|---|---|
| `v` | protocol version `1` |
| `n` | base64url UTF-8 display name, at most 63 bytes |
| `fp` | lowercase SHA-256 hex fingerprint of the companion TLS certificate |

The listener binds port `0`; it reads the assigned port and registers mDNS only
after the listener is ready. TXT data is discovery metadata, not authority.

## TLS and pairing

Every connection uses TLS 1.3. Once paired, the Mac accepts exactly the
certificate whose SHA-256 DER fingerprint it saved at pairing. There is no
system-trust fallback.

The first pairing is deliberately user authenticated:

1. The user enables **Pair new Mac** in the Android companion.
2. The Mac sends a fresh 32-byte challenge over a candidate TLS connection.
3. Both sides derive the same six-digit comparison code from the challenge and
   the presented certificate fingerprint. The user compares the Mac's code to
   the Android companion screen and approves it on Android.
4. The Android companion issues a random 32-byte bearer token. The Mac saves
   that token and the exact presented certificate fingerprint.

An active MITM creates different certificate fingerprints and therefore
different comparison codes. A code alone never upgrades trust; only the
comparison plus Android approval does.

## Framing

Each TLS connection begins with one UTF-8 JSON envelope framed by a four-byte
unsigned big-endian length. Envelopes are capped at 1 MiB. The receiver rejects
malformed JSON, more than 512 files, negative sizes, and totals above its
configured limit.

`pair-begin` and `pair-confirm` use envelopes only. A `send` envelope carries
the paired token and sanitized file metadata; after an `accepted` envelope,
files follow in metadata order as exactly their advertised byte counts. The
receiver writes every file to a staged MediaStore download before exposing it.

The companion requires an explicit user Accept/Decline notification for each
offer. It responds with `complete` only after every staged file has been
committed.

## Availability

Pairing persists. Availability does not: Android can stop a receiver after a
reboot or foreground-service time limit. The companion presents a Quick
Settings tile and a visible **Ready to receive from Mac** notification so the
user can re-enable it without reopening the app.
