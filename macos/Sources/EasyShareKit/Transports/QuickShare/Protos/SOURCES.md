# Quick Share protocol definitions

These schemas are vendored to make the byte-level protocol reviewable and to
keep generation reproducible. They are not authored by EasyShare.

Current source baseline, retrieved 2026-09-03:

- `offline_wire_formats.proto` — `google/nearby`
  `6d0ab62bb9e27cadac4a285ac46f886f293db2e1`,
  `connections/implementation/proto/offline_wire_formats.proto`
- `wire_format.proto` and `proto/sharing_enums.proto` — `google/nearby`
  `6d0ab62bb9e27cadac4a285ac46f886f293db2e1`,
  `sharing/proto/wire_format.proto` and `proto/sharing_enums.proto`
- `ukey.proto`, `securemessage.proto`, `securegcm.proto`, and
  `device_to_device_messages.proto` — Chromium-derived Google schemas, retained
  here with their Apache-2.0 headers.

The `Wire/Generated/*.pb.swift` files were generated with `protoc 29.3` and
`protoc-gen-swift` from SwiftProtobuf 1.38.1 (the exact package revision is
locked in `macos/Package.resolved`). Re-run generation only after
reviewing an upstream revision and recording it here. Do not hand-edit the
generated files.
