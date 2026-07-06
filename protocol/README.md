# WearLink — Shared Protocol

Single source of truth for the BLE wire format between the iOS app and the
Wear OS app. **Both apps import generated code from `proto/wearlink.proto`.**

## Files
- `GATT.md` — service + characteristic UUID table, connection params, bonding.
- `codec.md` — frame layout, chunking, CRC-8, ack model, replay protection.
- `proto/wearlink.proto` — all messages (link, health, call, notif, music).
- `gen/` — generated output (Swift + Dart). Committed after first `protoc` run.

## Generate code
Requires `protoc` + language plugins. The iOS CI workflow runs the Swift step
automatically (`../.github/workflows/build-ios.yml`).

```bash
# one-time tooling
brew install protobuf
brew install swift-protobuf              # protoc-gen-swift
dart pub global activate protoc_plugin     # protoc-gen-dart

# iOS — output lives under the XcodeGen-sourced WearLink tree:
mkdir -p ../ios_app/WearLink/Generated
protoc --swift_out=../ios_app/WearLink/Generated -I proto proto/wearlink.proto

# Wear OS — output committed under lib/gen:
protoc --dart_out=../wear_app/lib/gen -I proto proto/wearlink.proto
```

Then:
- iOS: `WearLink/Generated/` is inside the `WearLink` target's `sources` path
  (`WearLink`), so XcodeGen picks it up automatically.
- Wear OS: import `package:wear_app/gen/wearlink.pb.dart` etc. from `lib/gen/`.

## When the contract changes
1. Edit `proto/wearlink.proto` (and `GATT.md` / `codec.md` if wire-level).
2. Regenerate both languages.
3. Update the **mirror tables** by hand if a UUID changed:
   - iOS: `WearLink/BLE/BluetoothUUIDs.swift`
   - Wear OS: native Kotlin `BlePeripheralService.kt` service/char UUIDs + `lib/ble/gatt_client.dart`.
4. Bump `HealthFrame.sequence` expectations / nonce widths as needed.

Drift between this folder and the apps = the #1 class of bug here. Keep them
in lockstep; CI should diff generated output vs committed output.