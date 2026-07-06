# WearLink — Progress Tracker

> Source of truth for project status. Update after each work session.
> Architecture spec: see `Software-Structure.md`.

Last updated: 2026-07-06 (Wear OS build verified; iOS pending macOS)

---

## Project Status: **Phases 3-5 code complete (Call, Notification+ANCS, Music); APK verified**

Verified locally (Linux host):
- `flutter analyze` → **No issues found**
- `flutter test` → **9/9 pass** (PacketCodec round-trip/CRC-8 0xF4/reassembly + widget boot smoke)
- `flutter build apk --debug` → **success** (`build/app/outputs/flutter-apk/app-debug.apk`)
  → proves Kotlin (GATT server + HealthCollector + plugins) + Gradle + Wear OS manifest compile.
- Dart proto codegen → `wear_app/lib/gen/wearlink.pb.dart` (regenerated with CALORIES + DISTANCE_METERS)

NOT verified locally (impossible on Linux):
- iOS native app build (needs macOS + XcodeGen + CocoaPods + protoc). CI workflow `.github/workflows/build-ios.yml` is the verify path — push to `main` to run it and download the SideStore IPA artifact.
- On-device BLE round-trip on iPhone 14 Pro + Galaxy Watch 7 (needs both devices).

---

## Decisions (locked)

| Decision | Choice |
|---|---|
| iOS stack | Native Swift / SwiftUI + **CocoaPods** |
| Wear OS stack | **Flutter** + **signals_dart** + native Kotlin platform channels (BLE peripheral + Health Services) |
| BLE roles | **iOS = Central**, **Watch = Peripheral** |
| Wire protocol | Custom GATT service + protobuf payloads (shared `protocol/`) |
| Pairing | Bonded LE Secure Connections |
| Audio routing | Not attempted (platform-blocked) |
| Notification scope | Plumbing only; 3rd-party forwarding blocked by iOS sandbox |
| Music scope | Own-app control feasible; system control blocked |

---

## Roadmap

Legend: `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked by platform

### Phase 0 — Project scaffolding
- [x] Create `wear_app/` directory; move root Flutter project into it
- [x] Update `pubspec.yaml` name, add `signals`, `protobuf`, `protoc_plugin` deps
- [x] Configure Wear OS `android` module for watch form factor (minSdk 30, watch feature, permissions, Health Services + WorkManager deps)
- [x] Create `ios_app/` native Swift project scaffold (project.yml for XcodeGen, NOT .xcodeproj — generate on macOS)
- [x] Add `Podfile` (SwiftProtobuf + Zip), Info.plist, entitlements, NotificationServiceExtension target
- [x] Create `protocol/` + `GATT.md` + `codec.md` + `proto/wearlink.proto` + README
- [ ] Set up protoc codegen for Swift (ios) and Dart (wear) — tooling install only, run on macOS
- [ ] Verify `flutter pub get` + `xcodegen generate` + `pod install` succeed (needs macOS)

### Phase 1 — BLE link (foundation)
- [x] Define GATT service + characteristics in `protocol/GATT.md`
- [x] Implement packet codec (framing + CRC8/SMBUS-style + chunking) — both sides, unit-tested (Swift `PacketCodec.swift` + `PacketCodecTests.swift`; Dart `packet_codec.dart` + `packet_codec_test.dart`; known-answer vector 0xF4 synced)
- [x] Watch: native Kotlin `BlePeripheralService.kt` — advertiser + `BluetoothGattServer` + CCCD notify
- [x] Watch: `ble_peripheral_channel.dart` platform bridge (MethodChannel + EventChannel) + `ble_signal.dart` (signals_dart)
- [x] Watch: `WearLinkBlePlugin.kt` FlutterPlugin registered in `MainActivity`
- [x] iOS: `BLEManager.swift` (CBCentralManager, duty-cycled scan) + `GattClient.swift` (discover/subscribe + reassembly + dispatch)
- [ ] Pairing/bonding flow + reconnect on drop (basic reconnect scan present; explicit bonding UX pending)
- [x] Link Control heartbeat + ack (iOS sends heartbeat, echoes inbound LinkControl)
- [x] Build verification (Wear OS): `flutter analyze` clean, `flutter test` 9/9, `flutter build apk --debug` OK
- [ ] Verify: connect, send 1 byte round-trip, disconnect, reconnect — **needs real devices**
- [ ] Integration test on Wear OS device: `flutter test integration_test/app_test.dart -d <wear-os>` (harness added; no emulator on host)

### Phase 2 — Health data sync
- [x] Watch: `HealthCollector.kt` via Wear OS Health Services (passive HR/steps/calories/distance + sleep detection + active HR)
- [x] Watch: `HealthServicesPlugin.kt` platform channel bridge
- [x] Watch: `health_services_channel.dart` + `health_signal.dart` (signals_dart with BLE buffer)
- [x] Watch: `health_screen.dart` UI (live HR, steps, calories, distance, sleep state)
- [x] Proto: added CALORIES + DISTANCE_METERS types
- [ ] Watch: batch + delta-compress + queue on disconnect
- [ ] Watch: `Health Stream` notify + `Health Control` write (interval config)
- [ ] iOS: receive, decode, dedupe, write to HealthKit (`Health/` + `Storage/HealthStore.swift`)
- [ ] HealthKit write permissions UX
- [ ] Replay queued samples on reconnect
- [ ] Battery measurement: 24 h passive idle log

### Phase 3 — Call handling
- [x] iOS: `CallController.swift` — CXCallObserver + CXProvider delegate + CNContactStore lookup
- [x] iOS: encode `CallEvent` proto → BLE write to `callEvent` characteristic
- [x] iOS: decode `CallAction` from watch → `CXTransaction` (accept/reject/end/mute)
- [x] Watch: `call_signal.dart` — reactive state (incomingCall, callActive, muted, outgoing)
- [x] Watch: `call_screen.dart` — circular UI (idle/incoming/active/outgoing states)
- [x] Watch: `CallAction` write → iOS via BLE
- [ ] Latency test: incoming call → watch render < 1.5 s
- [x] Document: call audio stays on phone (non-goal)

### Phase 4 — Notification forwarding
- [x] iOS: `NotificationForwarder.swift` — encode `WearNotification` proto → BLE write
- [x] iOS: decode `NotifAction` from watch (dismiss/reply)
- [x] Watch: `AncsClient.kt` — BLE central mode, ANCS service discovery + notification reading
- [x] Watch: `AncsPlugin.kt` + `ancs_channel.dart` — platform bridge
- [x] Watch: `notification_signal.dart` — reactive state (notifications list, unread count)
- [x] Watch: `notification_screen.dart` — circular UI (list, dismiss)
- [ ] NotificationServiceExtension app-group bridge (ANCS handles main path)
- [x] Document: 3rd-party forwarding via ANCS (unblocked!)

### Phase 5 — Music control
- [x] iOS: `MusicController.swift` — MPNowPlayingInfoCenter + MPRemoteCommandCenter
- [x] iOS: encode `MusicNowPlaying` proto → BLE notify
- [x] iOS: decode `MusicCommand` from watch → dispatch to command center
- [x] Watch: `music_signal.dart` — reactive state (nowPlaying, position, volume)
- [x] Watch: `music_screen.dart` — circular UI (art, transport, volume, seek)
- [ ] Album art downscale + send over BLE (≤2 KB)
- [x] Document: system-media control blocked (own-app only)

### Phase 6 — Battery hardening
- [ ] Tune advertising intervals (idle vs active)
- [ ] Tune connection interval + slave latency
- [ ] Phone scan duty-cycle (2 s on / 8 s off)
- [ ] Coalesce events; batch writes
- [ ] WorkManager scheduling for watch periodic sync (Doze-aware)
- [ ] 24 h battery instrumentation both devices → log below

### Phase 7 — Polish & ship
- [ ] Error handling + reconnect UX
- [ ] Settings (sample interval, sync on charger only, etc.)
- [ ] Accessibility + small-screen layout pass
- [ ] App Store / Play (Wear OS) review prep
- [ ] README + user-facing docs

---

## Metrics Log

> Fill after each battery/latency run. Format: `YYYY-MM-DD | test | device | result`.

| Date | Test | Device | Result |
|---|---|---|---|
| — | idle BLE 24 h | watch | (pending) |
| — | idle BLE 24 h | phone | (pending) |
| — | call latency | phone→watch | (pending) |
| — | music RTT | watch→phone→watch | (pending) |

---

## Blockers / Open Questions

## Blockers / Open Questions

1. **Notification forwarding** — 3rd-party notifs blocked by iOS sandbox. Need user decision: relay server (opt-in) or placeholder-only?
2. **Music control** — system media blocked via public API; private `MediaRemote` = App-Store rejection. Confirmed own-app scope.
3. **SpO2 / HRV / sleep stages** — not available via Health Services 1.1.0-rc02. User may explore Samsung Health SDK bypass later.
4. **iOS dev account** — NotificationServiceExtension requires its own App ID + entitlements; confirm account available. SideStore testing avoids account for unsigned builds.
5. **On-device BLE verification** — Phase 1 not yet flashed/tested on iPhone 14 Pro + Galaxy Watch 7. First real milestone.
6. **UUID strategy** — using Bluetooth SIG base (0000xxxx-...-00805F9B34FB) for dev; must switch to a random 128-bit base before any public release (SIG base is reserved).

---

## Changelog

- **2026-07-06** — Created `Software-Structure.md` + this tracker. Decisions locked (iOS native+CocoaPods, Wear Flutter+signals_dart, iOS=central/watch=peripheral). No code yet.
- **2026-07-06** — Phase 0: rehomed Flutter project into `wear_app/` (renamed package `com.wearlink.app`, minSdk 30, watch feature + permissions, Health Services + WorkManager deps); scaffolded `ios_app/` (XcodeGen `project.yml`, Podfile SwiftProtobuf+Zip, Info.plist, entitlements, BLE core Swift, NotificationServiceExtension target, README); wrote shared `protocol/` (GATT.md, codec.md, wearlink.proto, README). Codegen tooling install + macOS build verification still pending.
- **2026-07-06** — Build verification pass: fixed signals API (`debugLabel` not `name`, `watchSignal` from `signals_flutter`), added missing `dart:typed_data`/`services.dart` imports, fixed widget-test channel mock; fixed Health Services dep coordinate `androidx.health:health-services-client:1.1.0-rc02` (was wrong group `androidx.health.services`); fixed Kotlin `BluetoothGattServerCallback` signatures (added `requestId`, correct param order) + `sendResponse` + `BluetoothGatt` import. `flutter analyze` clean, `flutter test` 9/9, `flutter build apk --debug` → `app-debug.apk` (151 MB). Added integration-test harness (`integration_test/app_test.dart` + `test_driver/integration_test.dart`). iOS build still needs macOS — CI is its verify path.
- **2026-07-06** — Phase 2 (Health): created `HealthCollector.kt` (passive HR/steps/calories/distance + sleep detection + active HR), `HealthServicesPlugin.kt`, `health_services_channel.dart`, `health_signal.dart`, `health_screen.dart`. Added `CALORIES` + `DISTANCE_METERS` to proto. Ran Dart proto codegen. Added `fixnum` dep. Registered plugin in `MainActivity`. CI fixes: test destination `name=iPhone 16,OS=18.5`, unsigned export uses manual IPA packaging (no signing). Podfile: added `WearLinkTests` with `SwiftProtobuf`. `flutter analyze` clean, `flutter test` 9/9, `flutter build apk --debug` OK.
- **2026-07-06** — Phases 3-5 (Call, Notification+ANCS, Music): implemented all iOS controllers (CallController with CXCallObserver+CNContactStore, NotificationForwarder with WearNotification proto, MusicController with MPNowPlayingInfoCenter+MPRemoteCommandCenter). Created ProtoSerialization.swift (manual protobuf encode/decode) + ProtoModels.swift (all message structs). Created AncsClient.kt (BLE central mode, ANCS service discovery, notification reading). Created AncsPlugin.kt + ancs_channel.dart platform bridge. Created watch signals (call_signal, notification_signal, music_signal) with reactive state + BLE buffer. Created watch UIs (call_screen, notification_screen, music_screen) with circular card design. iOS tab navigation (RootView with TabView) + feature screens (CallView, HealthView, NotificationView, MusicView). BLE onPayload handlers wired for callAction, notificationAction, musicCommand. `flutter analyze` clean, `flutter test` 9/9, `flutter build apk --debug` OK.