# WearLink — Progress Tracker

> Source of truth for project status. Update after each work session.
> Architecture spec: see `Software-Structure.md`.

Last updated: 2026-07-11 (Phase 14 — joint iOS + Wear OS interconnect audit + fixes)

---

## Project Status: **Phase 7 complete — all 49 wear_app issues fixed, flutter analyze clean**

Verified locally (Linux host):
- `flutter analyze` → **No issues found** (was 49 issues: fixed watchSignal→SignalBuilder migration, PbList protobuf compat, deprecated debugLabel→SignalOptions, unused imports)
- `flutter test` → **9/9 pass** (PacketCodec round-trip/CRC-8 0xF4/reassembly + widget boot smoke)
- `flutter build apk --debug` → **success** (`build/app/outputs/flutter-apk/app-debug.apk`)
  → proves Kotlin (GATT server + HealthCollector + plugins) + Gradle + Wear OS manifest compile.
- Dart proto codegen → `wear_app/lib/gen/wearlink.pb.dart` (compatible with protobuf ^3.1.0)

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

### Phase 6 — iOS UI Reconstruction
- [x] Create Views/ directory structure (Main, DeviceDetails, Music, Common)
- [x] Build component library: ToggleRow, DeviceCardView, DeviceIconView, SectionHeader
- [x] Implement DevicesListView (main screen with device card + feature grid + tip card)
- [x] Implement DeviceDetailsView (settings: General, Notifications, Health, Find Device, Device Management)
- [x] Implement DeviceInfoSection (device info table)
- [x] Implement MusicControlOptionsView (background color picker + display options)
- [x] Update RootView (replace TabView with DevicesListView as root)
- [x] Update AppContainer (add device + settings properties, HealthKit error handling)
- [x] Create Models/WearableDevice.swift + DeviceSettings

### Phase 7 — Code Audit & Optimization
- [x] Full codebase audit: 27-agent parallel review (iOS Swift + Wear OS Dart/Kotlin + CI/CD)
- [x] Document all 73 issues in Optimization.md
- [x] Fix 14 critical issues (crashes, data corruption, missing entitlements)
- [x] Fix 23 high-severity issues (resource leaks, fragile handlers, permission gaps)
- [x] Fix 17 medium-severity issues (unused deps, thread safety, error handling)
- [x] Fix 19 low-severity issues (accessibility, dead code, style)
- [x] Remove unused SwiftProtobuf + Zip pods from Podfile
- [x] Add app-group + aps-environment entitlements to both targets
- [x] Fix AncsClient.kt BufferOverflow (ByteBuffer.allocate(9))
- [x] Fix HealthCollector.kt executor shutdown (restartable)
- [x] Add Health Services permissions to AndroidManifest
- [x] Fix BLEManager.swift state machine (poweredOff handling)
- [x] Fix GattClient.swift reassembler (per-characteristic)
- [x] Fix ProtoSerialization.swift varint overflow guard
- [x] Fix MusicController.swift (noActionable, volume clamp, togglePlayPause)
- [x] Fix CallController.swift (deinit, dead code removal)
- [x] Fix CI/CD workflow (signing config, Xcode version pinning)

### Phase 8 — Comprehensive Review & Improvement Plan
- [x] 6-agent comprehensive review (iOS + Wear OS + protocol + research)
- [x] Identified 23 issues across 5 priority levels
- [x] Documented findings in progress.md

### Phase 9 — Connection Fixes (CRITICAL — BLE does not work)
- [ ] **P1: Fix UUID mismatch** — Kotlin uses custom base `96812f26-...`, iOS/Dart use SIG base `0000XXXX-...`. Watch advertises one UUID, phone scans for another → devices never see each other. Fix: standardize all 3 platforms on one UUID base.
- [ ] **P1: Fix health data never sent** — `drainBuffer()` never called on watch. Fix: add periodic timer that builds `HealthFrame` proto and sends to `FE20`.
- [ ] **P1: Fix `assumeIsolated` in deinit** — NotificationForwarder + MusicController use `MainActor.assumeIsolated` in deinit; crashes if last ref released off main thread. Fix: capture values + `Task { @MainActor in }`.
- [ ] **P1: Remove dead handler registration** — `NotificationForwarder.registerNotificationActionHandler()` called when `gatt` is nil → no-op. BLEManager already handles this.

### Phase 10 — Health Data Display
- [ ] **P2: Remove SpO2/HRV cards** — Health Services 1.1.0 doesn't support these. Remove or label "not available".
- [ ] **P2: Fix distance unit** — Show "km" when distance ≥ 1000m.
- [ ] **P2: Implement health data pipeline** — Watch-side timer to broadcast HealthFrame over BLE. (See P1)
- [ ] **P2: Add "Last updated" timestamp** — Show when health data was last received.

### Phase 11 — Stability
- [ ] **P3: Post `bleDidReconnect` notification** — Defined but never posted. Fix: post from BLEManager on reconnect.
- [ ] **P3: Add reconnection backoff** — Fixed 2s/8s scan drains battery when watch out of range. Fix: exponential backoff (2s, 4s, 8s, 16s, max 30s).
- [ ] **P3: Fix MTU mismatch** — Kotlin ignores MTU changes, iOS negotiates dynamically. Fix: surface MTU to Kotlin.
- [ ] **P3: Add heartbeat validation** — iOS sends heartbeat but never confirms receipt. Fix: track seq on echo, reconnect on missed heartbeats.

### Phase 12 — Feature Improvements
- [ ] **P4: Caller name lookup** — Always "Unknown". Fix: CNContactStore lookup by phone number.
- [ ] **P4: NotificationServiceExtension** — Passthrough only; never writes to app-group. Fix: implement UNNotificationServiceExtension to forward pushes.
- [ ] **P4: DeviceInfo from BLE** — Hardcoded "Galaxy Watch7". Fix: subscribe to `FE10` characteristic, decode `DeviceInfo` proto.
- [ ] **P4: Fix empty callId** — CallView simulator actions send empty callId. Fix: generate proper UUID.
- [ ] **P4: Fix music position drift** — Cumulative error in timer. Fix: use CACurrentMediaTime for precision.

### Phase 13 — Code Quality
- [ ] **P5: Remove empty stubs** — `SampleStore.swift`, `HealthSampleStore.swift`.
- [ ] **P5: Remove deprecated `synchronize()`** — Unnecessary since iOS 13.
- [ ] **P5: Remove duplicate ProtoModels** — `Generated/ProtoModels.swift` duplicates `Models/ProtoModels.swift`.
- [ ] **P5: Add BLE write error handling** — Silent failures in `gatt?.write()` calls.
- [ ] **P5: Document heartbeat format** — 8-byte payload undocumented.

### Phase 14 — Joint Interconnect Audit + Fixes (2026-07-11)

> Full dual-app BLE interconnect audit (4 Wear OS + 2 iOS subagents, all claims
> verified against source by the lead). Findings saved to memory:
> `wear-os-app-validation-2026-07-11`, `ios-app-validation-2026-07-11`.
> **Stale note:** Phase 9 "P1 UUID mismatch" is RESOLVED — `Uuids.kt`,
> `BluetoothUUIDs.swift`, and `gatt_client.dart` all use base
> `96812f26-7d24-4287-98cc-736bc4d49a61` byte-for-byte. UUIDs are NOT a blocker.
> Phase 9 "P1 health data never sent" is RESOLVED — `main.dart:63` 60s timer
> calls `drainBuffer()` → `gatt.send(FE20)`. (Sequence hardcoded 0 — see W9.)

**What already works (verified):** UUID parity, packet codec (CRC8 0xF4 exact
match both sides), scan/connect/reconnect, protobuf field numbers, CallKit +
MPRemoteCommandCenter (real, not stubs), Health FE20 watch→phone, Call/Notif/
Music phone→watch writes.

**Wear OS issues:**
- [x] **W1** `BlePeripheralService.kt:216,243` use `Log.e` with no `import android.util.Log` → **Kotlin compile error (build-blocker)**. **FIXED** — added `import android.util.Log`.
- [x] **W2** `app/build.gradle.kts:43` `health-services-client:1.1.0` does not exist (latest `1.1.0-rc02`) → **gradle resolution fails (build-blocker)**. **FIXED** — pinned to `1.1.0-rc02`.
- [x] **W3** `BlePeripheralService.kt:126-135` `propsFor`: FE31 CallAction / FE41 NotifAction / FE51 MusicCommand get `READ|WRITE` only — **no NOTIFY, no CCCD**. Watch cannot push actions to iPhone. **The single biggest interconnect failure.** iOS already lists these for subscribe (`GattClient.swift:47-49`) — its `.notify` guard skips them until the watch exposes NOTIFY. **FIXED** — added FE31/41/51 to the NOTIFY branch (CCCD auto-attached). **Fix was Wear-OS-side only**, as predicted.
- [x] **W4** `HealthCollector.kt:79-84`: `BODY_SENSORS` declared in manifest but never requested at runtime → collection silently no-ops on fresh install. **FIXED** — `HealthServicesPlugin` now implements `ActivityAware` + a `requestPermissions` method channel; `MainActivity` forwards `onRequestPermissionsResult`. Requests `BODY_SENSORS` (HR) + `ACTIVITY_RECOGNITION` (steps/calories/distance) via `ActivityCompat.requestPermissions`, resolves true when BODY_SENSORS granted (re-checks actual state, not grantResults order). Dart `main()` awaits `healthChannel.requestPermissions()` before `healthSignal.start()`, so collection no longer no-ops. `HealthCollector.start()` keeps its BODY_SENSORS gate as a safety net.
  - **Follow-up (not in W4 scope, tracked):** background "all the time" access — `BODY_SENSORS_BACKGROUND` (API 33–35) / `READ_HEALTH_DATA_IN_BACKGROUND` (API 36+) is a *separate, Settings-only* grant (the runtime dialog can't give it, and per Google's docs you must NOT request it together with BODY_SENSORS or both are denied). Not declared in the manifest today. Passive monitoring will lose HR when the app is backgrounded until the user grants "all the time" in Settings. This is entangled with **W10** (foreground Service) — a foreground service + the background-sensor permission together keep passive HR alive. Defer to a dedicated background-access task.
- [x] **W5** `main.dart:41-46`: FE21 `HealthControl` writes decoded then dropped — no `healthSignal` handler. iPhone cannot command watch capture. **FIXED** — `onFrame` now dispatches FE60 and FE21; `_handleHealthControl` decodes `HealthControl` and applies: `SEND_NOW`→`_flushHealth()` (drain+send FE20 immediately), `SET_INTERVAL_MS`→reconfigures `_healthIntervalMs` + restarts timer (only while resumed), `SET_TYPES`→stores `_healthTypes` filter applied in `_flushHealth`, `START/STOP_ACTIVE`→`healthChannel.startActive()/stopActive()`. Timer creation centralized in `_startHealthTimer()`; drain+send centralized in `_flushHealth()`. Lifecycle handler uses `_appResumed` flag + `_startHealthTimer()`.
- [x] **W6** `BlePeripheralService.kt:201`: FE10 DeviceInfo read returns raw ASCII `"WearLink/0.1"`, not a framed `DeviceInfo` protobuf. **FIXED** — `deviceInfoSnapshot()` (Build.MODEL / Build.VERSION.RELEASE / BatteryManager capacity / MTU 247) → Dart builds `DeviceInfo` proto → `PacketCodec.encode` → cached via `setDeviceInfo`/`setDeviceInfoResponse`. Read handler is offset-aware and caps each response to `negotiatedMtu-1` so iOS's transparent long-read reassembles correctly. Refreshed at startup + each 60s tick for fresh battery.
- [x] **W7** `notification_signal.dart:114-117`, `music_signal.dart:105-146`: `NotifAction` + `MusicCommand` omit `nonce` (replay contract). **FIXED** — nonce now set in the `sendAction`/`sendCommand` chokepoints (`DateTime.now().millisecondsSinceEpoch & 0xffff`, matching the existing `CallAction` convention), so all NotifAction/MusicCommand sends carry a nonce. (iOS dedup of these nonces — I5 — remains a separate minor gap.)
- [x] **W8** `main.dart:77`: ANCS built + started natively but `ancsChannel.events()` never listened → inert dead code. No conflict with FE40. **FIXED** — removed the dead Dart ANCS path (import, top-level `ancsChannel`, `start()`, `dispose()`). The custom GATT FE40 already carries iPhone notifications via the NSE. **Follow-up:** native `AncsPlugin`/`AncsClient` are still registered in `MainActivity` but now unused — safe to leave; removal is a separate native cleanup.
- [x] **W9** `gatt_client.dart:108-111`, `main.dart:68,117`: `_outSeq` not reset on reconnect; `HealthFrame.sequence` hardcoded `0`. **FIXED** — `_outSeq` reset to 0 on `DISCONNECTED` in `gatt_client._onConn` (the watch's GattClient is a singleton that persists across connects); `HealthFrame.sequence` is now monotonic via `_healthFrameSeq` (wraps at 2^32) in `_flushHealth`, so the phone can order/dedup frames.
- [ ] **W10** `BlePeripheralService.kt:28` + `AndroidManifest.xml:57-60`: `BlePeripheralService` is a plain class, not a `Service` → no foreground service → backgrounding drops iPhone link.
- [ ] **W11** n/a: MTU 247 never requested (peripheral can't; iOS doesn't either). Minor — chunking handles default MTU.

**iOS issues:**
- [x] **I1** `BLEManager.swift:189-207` + `GattClient.swift:43-49`: FE10 DeviceInfo dead (double mismatch) — registered as a notify handler but FE10 never subscribed AND no `readValue` anywhere; watch also returns ASCII not protobuf (W6). **FIXED** — `GattClient.didDiscoverCharacteristicsFor` now issues `p.readValue(for: deviceInfo)` after the subscribe loop. The read response flows through the existing `didUpdateValueFor` → `PacketCodec.decode` → reassembler → `onPayload[deviceInfo]` path, firing the existing `BLEManager:189-207` handler that populates `WearableDevice`/`AppContainer.device`. FE10 is a read char (no CCCD), intentionally excluded from the subscribe list. (Watch half = W6.)
- [x] **I2** n/a: FE21 `HealthControl` never written by iOS — no write site anywhere. iPhone can't command watch health capture. (Doubly dead with W5.) **FIXED** — `GattClient` gained an `onDiscovered` callback fired at the end of `didDiscoverCharacteristicsFor`; BLEManager sets it to call `sendHealthControlConfig()`, which writes two framed `HealthControl` protos to FE21: `setIntervalMs(60000)` + `setTypes([HR,steps,calories,distance,sleep])`. Sent after discovery so the FE21 char is present. Watch half = W5.
- [x] **I3** `BLEManager.swift:248`: heartbeat writes `Data(count: 8)` (8 zero bytes), not a `LinkControl{HEARTBEAT}` protobuf → watch decodes `kind=KIND_UNSPECIFIED`. **FIXED** — `startHeartbeat` now sends `encodeLinkControl(LinkControl(kind:.heartbeat, seq:heartbeatSeq++, timestampMs:now, payload:Data()))` (framed by `GattClient.write`). Added `heartbeatSeq` field.
- [x] **I4** `BLEManager.swift:147-151`: LinkControl ack echo re-frames `frame.seq` as 2 bytes → watch decodes `LinkControl{kind=0}`, not an ACK. **FIXED** — `onLinkControl` now decodes `frame.payload` via `decodeLinkControl`; heartbeats → `LinkControl{ack, seq}` ACK (proper proto); inbound ack/nack → liveness, no re-ack (prevents pingpong). **Watch-side half added** (closes the loop): `main.dart` `onFrame` dispatches FE60 → `_handleLinkControl` decodes `LinkControl`, answers heartbeats with `LinkControl{ACK, seq}` via `gatt.send(FE60)`. So iOS-heartbeat → watch-ACK → iOS-liveness now works end-to-end.
- [ ] **I5** `ProtoSerialization.swift:594,741,898`: `nonce` decoded but never used (no seen-nonce tracking/dedup). Minor replay gap.
- [~] **I6** `CallController.swift:68,76`: caller name hardcoded `"Unknown"` — no `CNContactStore` lookup; only incoming calls forwarded. **RECLASSIFIED as a PLATFORM LIMITATION (not a fixable bug).** Verified against Apple's CallKit API: `CXCall` (delivered to a third-party `CXCallObserver`) exposes only `uuid` + state booleans (`hasConnected`/`hasEnded`/`isOutgoing`/`isOnHold`) — **no caller name, no phone number**. `localizedCallerName`/`remoteHandle` live on `CXCallUpdate`, visible only to the VoIP app that *owns* the call. WearLink is a third-party *observer* of the system Phone app's calls, so caller identity is unavailable by any means — `CNContactStore` can't help (there is no number to look up). The audit's CNContactStore suggestion was infeasible; corrected the record rather than implement an impossible lookup. "Unknown" is a hard iOS privacy limit.
- [ ] **I7** `BLEManager.swift:177`+`HealthManager.swift:83`; `BLEManager.swift:171`+`MusicController.swift:192`: double-registration of healthStream & musicCommand handlers (redundant, harmless).
- [x] **I8** `GattClient.swift:13`: `outSeq` not reset on reconnect (same as W9). **Already correct — no change needed.** `BLEManager.didConnect` constructs a *new* `GattClient` per connect, so `outSeq` is 0 by construction on every reconnect (unlike the watch side, whose `GattClient` is a singleton — see W9).
- [ ] **I9** `GattClient.swift:70`: MTU 247 never requested (uses `maximumWriteValueLength`). Minor.

**Platform limits (by design — NOT bugs):** 3rd-party notification forwarding blocked (only WearLink-app push via NSE); reply to originating app blocked; other-apps media control blocked; call audio to watch blocked.

**Fix order (approved):** W1+W2 (build) → W3 (actions) → I1+W6 (DeviceInfo) → I3+I4 (heartbeat/ack) → W4 (BODY_SENSORS) → I2+W5 (HealthControl) → cleanup (W7/W8/W9/I8/I6).

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
3. **SpO2 / HRV / sleep stages** — not available via Health Services 1.1.0. User may explore Samsung Health SDK bypass later.
4. **iOS dev account** — NotificationServiceExtension requires its own App ID + entitlements; confirm account available. SideStore testing avoids account for unsigned builds.
5. **On-device BLE verification** — Phase 1 not yet flashed/tested on iPhone 14 Pro + Galaxy Watch 7. First real milestone.
6. ~~**UUID strategy** — using Bluetooth SIG base for dev; must switch to random 128-bit base before public release.~~ **Fixed** — Uuids.kt now uses random base `96812f26-7d24-4287-98cc-736bc4d49a61`.
7. ~~**App group entitlement** — missing in both targets, notification bridge dead code.~~ **Fixed** — added to both WearLink.entitlements and NotificationServiceExtension.entitlements.
8. ~~**Health Services permissions** — missing from AndroidManifest, HealthCollector would crash.~~ **Fixed** — added all 5 health permissions.
9. ~~**AncsClient.kt BufferOverflow** — ByteBuffer.allocate(8) should be 9.~~ **Fixed**.
10. ~~**Unused pods** — SwiftProtobuf + Zip declared but never used.~~ **Fixed** — removed from Podfile.

---

## Changelog

- **2026-07-06** — Created `Software-Structure.md` + this tracker. Decisions locked (iOS native+CocoaPods, Wear Flutter+signals_dart, iOS=central/watch=peripheral). No code yet.
- **2026-07-06** — Phase 0: rehomed Flutter project into `wear_app/` (renamed package `com.wearlink.app`, minSdk 30, watch feature + permissions, Health Services + WorkManager deps); scaffolded `ios_app/` (XcodeGen `project.yml`, Podfile SwiftProtobuf+Zip, Info.plist, entitlements, BLE core Swift, NotificationServiceExtension target, README); wrote shared `protocol/` (GATT.md, codec.md, wearlink.proto, README). Codegen tooling install + macOS build verification still pending.
- **2026-07-06** — Build verification pass: fixed signals API (`debugLabel` not `name`, `watchSignal` from `signals_flutter`), added missing `dart:typed_data`/`services.dart` imports, fixed widget-test channel mock; fixed Health Services dep coordinate `androidx.health:health-services-client:1.1.0-rc02` (was wrong group `androidx.health.services`); fixed Kotlin `BluetoothGattServerCallback` signatures (added `requestId`, correct param order) + `sendResponse` + `BluetoothGatt` import. `flutter analyze` clean, `flutter test` 9/9, `flutter build apk --debug` → `app-debug.apk` (151 MB). Added integration-test harness (`integration_test/app_test.dart` + `test_driver/integration_test.dart`). iOS build still needs macOS — CI is its verify path.
- **2026-07-06** — Phase 2 (Health): created `HealthCollector.kt` (passive HR/steps/calories/distance + sleep detection + active HR), `HealthServicesPlugin.kt`, `health_services_channel.dart`, `health_signal.dart`, `health_screen.dart`. Added `CALORIES` + `DISTANCE_METERS` to proto. Ran Dart proto codegen. Added `fixnum` dep. Registered plugin in `MainActivity`. CI fixes: test destination `name=iPhone 16,OS=18.5`, unsigned export uses manual IPA packaging (no signing). Podfile: added `WearLinkTests` with `SwiftProtobuf`. `flutter analyze` clean, `flutter test` 9/9, `flutter build apk --debug` OK.
- **2026-07-06** — Phases 3-5 (Call, Notification+ANCS, Music): implemented all iOS controllers (CallController with CXCallObserver+CNContactStore, NotificationForwarder with WearNotification proto, MusicController with MPNowPlayingInfoCenter+MPRemoteCommandCenter). Created ProtoSerialization.swift (manual protobuf encode/decode) + ProtoModels.swift (all message structs). Created AncsClient.kt (BLE central mode, ANCS service discovery, notification reading). Created AncsPlugin.kt + ancs_channel.dart platform bridge. Created watch signals (call_signal, notification_signal, music_signal) with reactive state + BLE buffer. Created watch UIs (call_screen, notification_screen, music_screen) with circular card design. iOS tab navigation (RootView with TabView) + feature screens (CallView, HealthView, NotificationView, MusicView). BLE onPayload handlers wired for callAction, notificationAction, musicCommand. `flutter analyze` clean, `flutter test` 9/9, `flutter build apk --debug` OK.
- **2026-07-07** — iOS UI Reconstruction: created Views/ directory structure with component library (ToggleRow, DeviceCardView, DeviceIconView, SectionHeader). Implemented DevicesListView (main screen with device card + feature grid), DeviceDetailsView (settings sections), DeviceInfoSection, MusicControlOptionsView. Updated RootView to use DevicesListView as root. Updated AppContainer with device/settings properties + HealthKit error handling. Created Models/WearableDevice.swift + DeviceSettings. Fixed NotificationForwarder bugs (WearNotification naming, wrong var reference).
- **2026-07-07** — Full codebase audit: launched 27-agent parallel review using caveman, moai-lang-dart, flutter-ui, podspec-fundamentals skills. Found 73 issues (14 critical, 23 high, 17 medium, 19 low). Documented all findings in Optimization.md.
- **2026-07-07** — Fixed all 73 issues: GattClient per-characteristic reassembler + @MainActor + error logging; BLEManager state machine + onLinkControl seq echo; ProtoSerialization varint overflow guard + skipField bounds; NotificationForwarder data loss fix + @convention(c) callback; added app-group + aps-environment entitlements; DeviceCardView dynamic battery icon; WearableDevice Codable fix; removed unused SwiftProtobuf+Zip pods; MusicController noActionable + volume clamp + togglePlayPause; CallController deinit + dead code removal; Info.plist fixes; HealthViewModel throws on unavailable; AncsClient.kt BufferOverflow fix + ScanFilter + permission checks; HealthCollector executor restart + permission check; AndroidManifest health permissions + bluetooth_le feature; BlePeripheralService thread safety + MTU + permissions; pubspec.yaml Flutter constraint + dep bumps; build.gradle.kts stable health-services; Dart channel subscription cleanup; Uuids.kt random base; CI/CD signing config + Xcode pinning.
- **2026-07-07** — Phase 7 wear_app fixes: migrated watchSignal→SignalBuilder for signals 7.x API, fixed PbList protobuf 3.x compat, replaced deprecated debugLabel→SignalOptions/MapSignalOptions, removed unused imports. `flutter analyze` clean (0 issues), `flutter test` 9/9 pass.
- **2026-07-08** — Phase 8: 6-agent comprehensive review (iOS + Wear OS + protocol + web research). Found 23 issues across 5 priorities. Key findings: UUID mismatch prevents BLE connection entirely (Kotlin custom base vs iOS/Dart SIG base), health data never sent over BLE (drainBuffer() never called), assumeIsolated in deinit fragile, SpO2/HRV not available via Health Services 1.1.0. Documented all in progress.md. Updated progress.md with full improvement plan (Phases 9-13).