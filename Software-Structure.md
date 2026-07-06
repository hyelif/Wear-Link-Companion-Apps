# WearLink — Software Architecture

> Companion bridge: **iOS (iPhone 14 Pro)** ⟷ **Wear OS (Samsung Galaxy Watch 7)** over BLE.
> Replaces the abandoned OrienLabs BLE bridge.

---

## 1. Goals & Non-Goals

### Goals
- iPhone ↔ Wear OS watch communication over BLE (GATT), no cloud relay.
- Battery-frugal: long connection intervals, batched sync, low duty-cycle advertising.
- Four features:
  1. **Health data sync** — watch collects → forwards to iPhone.
  2. **Call handling on watch** — incoming call UI on watch, accept/reject/mute controls.
  3. **Notification forwarding on watch** — iPhone notifications surfaced on watch.
  4. **Music control on watch** — watch controls now-playing media on iPhone.

### Non-Goals (hard platform limits — see §9)
- Routing phone **call audio** to the watch speaker. Not possible over BLE / not exposed by iOS.
- Forwarding **arbitrary 3rd-party app notifications** from iOS. iOS sandbox blocks this; see §9.
- Controlling **other apps' media playback** (Spotify/Apple Music) from the companion. Private API only; App-Store unsafe. See §9.

These limits are real and unavoidable on non-jailbroken iOS. The architecture is designed around them, not around pretending they don't exist.

---

## 2. Platform Stack

| Side | Stack | Role | State mgmt | BLE |
|------|-------|------|------------|-----|
| **iOS app** | Native Swift / SwiftUI, **CocoaPods** deps | **Central** (scanner/connect) | `@Observable` / `Combine` | CoreBluetooth |
| **Wear OS app** | **Flutter** UI + **`signals` (signals_dart)** state | **Peripheral** (advertiser/GATT server) | signals_dart | Native Kotlin `BluetoothGattServer` via platform channel |

> Flutter `flutter_blue_plus` is central-oriented; the **peripheral/GATT-server** side on Wear OS is implemented in native Kotlin (`BluetoothGattServer`) and exposed to Flutter via a `MethodChannel`. This gives fine-grained battery control over advertising/MTU/connection params that a pure-Flutter plugin cannot.

### Why mixed (native iOS + Flutter Wear)
- iOS side benefits from native CoreBluetooth, CallKit, and direct CocoaPods dependency control.
- Wear OS side benefits from Flutter UI velocity + `signals_dart` reactivity, while heavy BLE/health collection runs in native Kotlin for battery efficiency.

---

## 3. Repository Layout

```
wear_link/                         # repo root
├── progress.md                    # status tracker
├── Software-Structure.md          # this file
├── protocol/                       # shared GATT contract (single source of truth)
│   ├── GATT.md                     # service/characteristic UUID table + payloads
│   ├── codec.md                    # binary packet framing + protobuf sketch
│   └── proto/                      # .proto definitions (shared by both apps)
│
├── wear_app/                       # Wear OS Flutter app (moved from repo root)
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app/                     # root widget, theme, routing
│   │   ├── signals/                 # signals_dart state stores (one per feature)
│   │   │   ├── ble_signal.dart      # connection state signal
│   │   │   ├── health_signal.dart
│   │   │   ├── call_signal.dart
│   │   │   ├── notification_signal.dart
│   │   │   └── music_signal.dart
│   │   ├── ble/
│   │   │   ├── gatt_client.dart     # wraps native peripheral channel
│   │   │   └── packet_codec.dart     # encode/decode protocol buffers
│   │   ├── features/
│   │   │   ├── health/              # UI + sensor sync orchestration
│   │   │   ├── call/
│   │   │   ├── notification/
│   │   │   └── music/
│   │   └── platform/
│   │       ├── ble_peripheral_channel.dart
│   │       └── health_services_channel.dart
│   └── android/
│       └── app/src/main/kotlin/.../
│           ├── BlePeripheralService.kt   # BluetoothGattServer + advertiser
│           ├── HealthCollector.kt       # Wear OS Health Services API
│           ├── CallController.kt
│           └── MusicController.kt
│
└── ios_app/                        # native iOS app
    ├── WearLink.xcodeproj
    ├── Podfile                      # CocoaPods
    ├── WearLink/
    │   ├── App/                     # @main, scene, DI container
    │   ├── BLE/
    │   │   ├── BLEManager.swift     # CBCentralManager, connection lifecycle
    │   │   ├── GattClient.swift      # discover/read/write/subscribe
    │   │   └── PacketCodec.swift
    │   ├── Features/
    │   │   ├── Health/               # HealthKit writer (store incoming data)
    │   │   ├── Call/                  # CallKit CXProvider delegate
    │   │   ├── Notification/          # NotificationServiceExtension + forwarder
    │   │   └── Music/                 # MPNowPlayingInfoCenter / MPRemoteCommandCenter
    │   ├── Storage/
    │   │   └── HealthStore.swift      # local cache + dedupe before HealthKit write
    │   └── UI/                        # SwiftUI views
    └── NotificationServiceExtension/  # separate target, see §9 limitation
```

> The existing root Flutter scaffold is rehomed into `wear_app/`. `ios_app/` is a new native Swift project.

---

## 4. BLE GATT Protocol (contract lives in `protocol/`)

**iOS = Central, Watch = Peripheral.** Watch advertises a custom service; iPhone scans, connects, subscribes.

### Service & characteristic map

| UUID (short handle, 16-bit-assigned) | Type | Direction | Properties | Payload |
|---|---|---|---|---|
| `0xFE01` **WearLink Service** | service | — | — | — |
| `0xFE10` DeviceInfo | char | watch→phone | read | model, fw, battery%, mtu pref |
| `0xFE20` Health Stream | char | watch→phone | **notify** | batched protobuf health frames |
| `0xFE21` Health Control | char | phone→watch | write | "send now", sample config, interval set |
| `0xFE30` Call Event | char | phone→watch | write + notify | incoming call (caller, id, type) |
| `0xFE31` Call Action | char | watch→phone | write | accept / reject / mute / end |
| `0xFE40** Notification | char | phone→watch | write | app name, title, body, id, actions |
| `0xFE41** Notif Action | char | watch→phone | write | dismiss / reply-text |
| `0xFE50** Music NowPlaying | char | phone→watch | notify | title, artist, art thumb, duration, pos, state |
| `0xFE51** Music Command | char | watch→phone | write | play/pause/next/prev/seek/vol |
| `0xFE60** Link Control | char | bidirectional | write+notify | heartbeat, ack/nack, reconnect token |

Full byte layout, framing, and protobuf messages live in `protocol/GATT.md` + `protocol/proto/`. Both apps import the **same** proto so the wire format is defined once.

### Framing
- Each characteristic value = `[seq:u16][flags:u8][len:u16][payload[]]` + CRC8.
- Payloads > MTU split into chunks with continuation flag; reassembled on receive.
- Every write acknowledged via `Link Control` (ack with seq) — idempotent retries on BLE drop.
- Encryption: bonded link (LE Secure Connections) — no app-layer crypto needed beyond optional replay-nonce for action commands.

### Connection lifecycle & battery tuning
| Parameter | Value | Reason |
|---|---|---|
| Advertising interval (idle) | 1000 ms | low power, phone can wait |
| Advertising interval (active call) | 100 ms | responsiveness when phone pushes a call |
| Connection interval | 200–500 ms (request) | tradeoff latency vs power |
| Slave latency | 4 | watch skips empty intervals |
| Supervision timeout | 6 s | tolerate brief dropouts |
| MTU | 247 (negotiated up) | fewer chunks per health batch |
| Heartbeat | every 30 s via Link Control | detect silent disconnect, cheap |

Phone scans **duty-cycled**: scan 2 s, idle 8 s when disconnected; instant scan on call/notification/music event.

---

## 5. Feature Architecture

### 5.1 Health Data Sync
**Flow:** Watch collects (native Health Services) → batch every N min → BLE notify → iPhone receives → writes to HealthKit.

- Watch: `HealthCollector.kt` uses **Wear OS Health Services API** (`PassiveMonitoringClient` for passive HR/steps, `MeasureClient` for active high-rate when screen on). Avoid always-on active sensors unless feature explicitly requested.
- Batching: collect raw deltas, compress (delta-encoding), send one notify every 5–15 min or when buffer hits threshold. Configurable via `Health Control` write from phone.
- iPhone: `Health/` writes to **HealthKit** (`HKHealthStore`, write permissions for HR, steps, etc.). Dedupe + local cache before write so a dropped BLE link doesn't lose data; replay on reconnect.
- `HealthKit` write entitlement requires user-granted permission per type. Document required types in Podfile README.

### 5.2 Call Handling on Watch
**Flow:** iPhone detects incoming call (CallKit) → push caller to `Call Event` → watch shows call UI → user action → `Call Action` → iPhone acts via CallKit `CXProvider`.

- iPhone: `Call/C` subscribes to `CXCallObserver`, on `callChanged` with `isOutgoing=false && hasConnected=false` → encode caller (CN contact lookup) → BLE write `Call Event`.
- Watch: `call_signal.dart` exposes incoming-call state; UI shows accept/reject/mute. Action → BLE write `Call Action`.
- iPhone: receives `Call Action` → maps to `CXTransaction` (end, answer), `CXProvider.perform()`.
- **Limitation (non-goal):** call **audio** stays on phone. Watch is a **remote control only**. Cannot route carrier-call audio to watch over BLE. Documented in §9.

### 5.3 Notification Forwarding on Watch
**Goal:** show iPhone notifications on watch.

**Hard iOS wall — see §9.** iOS gives a 3rd-party app **no public API** to read notifications from other apps. What is feasible:

1. **NotificationServiceExtension** target — can intercept **push notifications targeting this app bundle** (e.g., a server pushes `{"_wl_fwd": {...}}` payloads to WearLink). Only useful if you run a forwarding server the user routes through.
2. **iOS Live Activities / Dynamic Island** — for the WearLink app's own content only.
3. **No general cross-app forwarding** — unlike Android's `NotificationListenerService`, iOS has no equivalent for arbitrary apps.

**Realistic scope for this project:** implement the NotificationServiceExtension path + UI on watch, but clearly mark in-progress/limited. True 3rd-party forwarding is **blocked by Apple** and out of scope without a relay server the user opts into. The architecture implements the **plumbing** (write `Notification` → watch renders → `Notif Action` reply) so that if a relay/proxy is later added it slots in.

### 5.4 Music Control on Watch
**Flow:** iPhone now-playing → notify `Music NowPlaying`; watch sends `Music Command` → iPhone acts.

- iPhone reads now-playing via `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` — **only for its own playback**. To control **system/other-app media** there is no public API (private `MediaRemote` framework → App Store rejection).
- Feasible scope: control **WearLink app's own** audio session media. For system control, mark as limited/blocked.
- Watch UI: album art thumbnail (sent over BLE, downsampled to ≤2 KB), title/artist, scrub bar, play/pause/next/prev, volume slider.

---

## 6. Battery Optimization Strategy

Cross-cutting; applies to both apps.

### Watch (peripheral)
- Low-duty advertising (1 s idle, 100 ms when call active).
- Long connection interval + slave latency; let phone do most work.
- Health collection **passive** by default; active high-rate sensors only on explicit user action or screen-on.
- Batch + delta-compress health; never stream raw samples.
- Defer non-urgent sync; piggyback on an open connection.
- Doze-aware scheduling via `WorkManager` for periodic sync; never wake the SoC for trivial work.
- Screen-off: drop advertising to min unless phone connected/bonded.

### iPhone (central)
- Scan duty-cycled (2 s on / 8 s off) when disconnected.
- Stop scanning immediately on connect; rely on connection.
- Background mode: `bluetooth-central` only. Avoid background health polling.
- Cache + batch HealthKit writes; flush on a timer, not per-sample.
- Coalesce notification/music events within a short window before writing BLE.
- Avoid CoreLocation; BLE only.

### Measurable targets (instrumented, logged to `progress.md`)
- Watch idle BLE cost < 3% battery / hour while bonded.
- Phone idle BLE cost < 1% / hour.
- Latency: call event → watch render < 1.5 s; music command round-trip < 400 ms.

---

## 7. State Management

### Wear OS (signals_dart)
- Each feature has a `Signal` store:
  - `bleSignal`: connection state (`FutureSignal` of enum), RSSI, MTU.
  - `healthSignal`: latest samples + sync queue length.
  - `callSignal`: current incoming call or null.
  - `notificationSignal`: list of active notifications.
  - `musicSignal`: now-playing + transport state.
- Platform channel pushes events into a `Stream`, `streamSignal`/`effectSignal` bridge to `signals`.
- UI uses `Watch(context).watch(signal)` / `signal.watch(context)` — no `setState`, no `setState` rebuilds of unrelated widgets.

### iOS (Combine + @Observable)
- `BLEManager` publishes connection state via `@Observable`.
- Feature view models are `@Observable` classes injected via a small DI container in `App/`.
- SwiftUI views subscribe; background state changes surface through `Combine` publishers bridged to the UI on main thread.

---

## 8. Dependencies

### iOS (`Podfile`, CocoaPods)
| Pod | Purpose |
|---|---|
| `SwiftProtobuf` | decode watch protobuf |
| `Zip` or `zlib-objc` | optional payload compression |
| (CoreBluetooth, CallKit, HealthKit, MediaPlayer) | system frameworks, no pod |

(Watch-side protobuf is generated from the shared `protocol/proto/*.proto`.)

### Wear OS (`pubspec.yaml` + Gradle)
| Dep | Purpose |
|---|---|
| `signals` (signals_dart) | reactive state |
| `flutter_blue_plus` | (central helper if ever needed; main path is native peripheral) |
| `protobuf` / `protoc_plugin` | generated Dart from shared proto |
| Native Kotlin: `androidx.health.services` (Wear OS Health Services), `androidx.work` (WorkManager), `androidx.compose` (any Compose bits in native layer) | health + scheduling |

---

## 9. Platform Limitations Register (honest constraints)

| Feature | iOS reality | Wear OS reality | Verdict |
|---|---|---|---|
| Health sync | HealthKit write permitted with user grant | Health Services passive OK | **Feasible** |
| Call control | CallKit detect + action OK | UI only | **Feasible** (control only, no audio) |
| Call audio to watch | Not exposed | n/a | **Blocked** |
| 3rd-party notif forwarding | No public API to read other apps' notifs | renders fine | **Blocked** without relay |
| Music control (own app) | MPRemoteCommandCenter OK | controls fine | **Feasible** |
| Music control (Spotify/Apple Music) | private `MediaRemote` only | n/a | **Blocked** (App-Store unsafe) |

These are surfaced explicitly so the project scope is honest. Features marked **Blocked** get UI placeholders + plumbing but are not promised to the user.

---

## 10. Testing & Verification

- **Unit:** packet codec round-trip (both sides, shared proto conformance).
- **Integration:** BLE loopback harness — one iOS simulator + one Wear OS emulator/emulator-with-BLE; verify each GATT char flow.
- **Battery:** on-device battery logger (battery % sampled each 10 min over 24 h idle) → feeds `progress.md` metrics.
- **Latency:** instrumented timing markers in protocol `Link Control` heartbeat + per-feature event timestamps.

---

## 11. Open Questions / Next Decisions
- Notification relay server: build one (user opts in to route notifications through it), or drop the feature to placeholder?
- Protobuf vs. flat CBOR: protobuf chosen for codegen parity; confirm.
- iOS provisioning: NotificationServiceExtension needs its own App ID + entitlements — confirm dev account.
- Watch-side BLE peripheral plugin vs. fully native: confirm native Kotlin `BluetoothGattServer` path (recommended).