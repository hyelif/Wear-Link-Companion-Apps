# Optimization & Verification Report

> Generated: 2026-07-07
> Scope: iOS app + Wear OS app full codebase audit
> Method: 27-agent parallel review using caveman, moai-lang-dart, flutter-ui, podspec-fundamentals skills

---

## Table of Contents

1. [iOS App — Critical Issues](#ios-app--critical-issues)
2. [iOS App — High Severity](#ios-app--high-severity)
3. [iOS App — Medium/Low](#ios-app--mediumlow)
4. [Wear OS App — Critical Issues](#wear-os-app--critical-issues)
5. [Wear OS App — High Severity](#wear-os-app--high-severity)
6. [Wear OS App — Medium/Low](#wear-os-app--mediumlow)
7. [CI/CD Issues](#cicd-issues)
8. [Full Review Details](#full-review-details)

---

## iOS App — Critical Issues

### 1. GattClient.swift — Single Reassembler shared across characteristics

**File:** `ios_app/WearLink/BLE/GattClient.swift:10`

`private let reassembler = Reassembler()` is a single instance keyed by `seq` (UInt16). If two different characteristics (e.g. `healthStream` and `callEvent`) send chunked frames with the same sequence number, the reassembler will mix chunks from the two streams together, producing corrupted payloads.

**Fix:** Use a per-characteristic reassembler:
```swift
private var reassemblers: [CBUUID: Reassembler] = [:]
```

---

### 2. GattClient.swift — Delegate set before handlers populated

**File:** `ios_app/WearLink/BLE/BLEManager.swift:98`

`peripheral.delegate = client` is set before `onLinkControl` and `onPayload` handlers are configured. If the peripheral delivers any delegate callbacks synchronously during this window, `client` would receive them before its handlers are ready.

**Fix:** Move `peripheral.delegate = client` to just before `client.discoverServices()` (after all handlers are set).

---

### 3. BLEManager.swift — State not updated on Bluetooth off

**File:** `ios_app/WearLink/BLE/BLEManager.swift:77`

```swift
nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
    guard c.state == .poweredOn else { return }  // silently drops all other states
    Task { @MainActor in
        self.startScanning()
    }
}
```

When `c.state` is `.poweredOff`, `.unauthorized`, or `.unsupported`, the method returns without updating `self.state`. The state machine stays in whatever state it was in (e.g., `.scanning`).

**Fix:** Add an `else` branch that sets `self.state = .poweredOff` and invalidates timers.

---

### 4. ProtoSerialization.swift — Varint overflow check off by one

**File:** `ios_app/WearLink/BLE/ProtoSerialization.swift:38`

```swift
if shift >= 64 { return nil } // overflow
result |= UInt64(byte & 0x7F) << shift
```

When `shift == 63` (10th varint byte), the guard passes because `63 < 64`. The code then evaluates `UInt64(byte & 0x7F) << 63`. If the byte's low 7 bits are >= 2, this shift overflows `UInt64` and traps at runtime.

**Fix:** Change guard to `if shift > 63` or add explicit check for `byte & 0x7F > 1` when `shift == 63`.

---

### 5. NotificationForwarder.swift — App group entitlement missing

**File:** `ios_app/WearLink/Features/Notification/NotificationForwarder.swift:11` / `WearLink.entitlements` / `NotificationServiceExtension.entitlements`

The code uses `UserDefaults(suiteName: "group.com.wearlink.notification")` but **neither target has the app-group entitlement configured**:

- `WearLink.entitlements` — no `com.apple.security.application-groups` key
- `NotificationServiceExtension.entitlements` — has a TODO comment but no actual key

Without the entitlement, `UserDefaults(suiteName:)` returns `nil` and the entire notification bridge is dead code.

**Fix:** Add to both entitlements files:
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.wearlink.notification</string>
</array>
```

---

### 6. WearLink.entitlements — Missing `aps-environment` entitlement

**File:** `ios_app/WearLink/Resources/WearLink.entitlements`

The app has a `NotificationServiceExtension` target. For remote push notifications to reach the app and its service extension, the main app **must** have the `aps-environment` entitlement.

**Fix:** Add to `WearLink.entitlements`:
```xml
<key>aps-environment</key>
<string>development</string>
```

---

### 7. DeviceCardView.swift — Battery icon hardcoded

**File:** `ios_app/WearLink/Views/Main/DeviceCardView.swift:28`

```swift
Image(systemName: isCharging ? "battery.100.bolt" : "battery.75")
```

When not charging, the icon is hardcoded to `"battery.75"` regardless of `batteryLevel`. If the level is 12%, the icon still shows a three-quarters-full battery.

**Fix:** Dynamically select SF Symbol based on actual level:
```swift
let batteryIcon: String = {
    if isCharging { return "battery.100.bolt" }
    switch batteryLevel {
    case 76...100: return "battery.100"
    case 51...75:  return "battery.75"
    case 26...50:  return "battery.50"
    case 1...25:   return "battery.25"
    default:       return "battery.0"
    }
}()
```

---

### 8. Models/WearableDevice.swift — DeviceSettings Codable bug

**File:** `ios_app/WearLink/Models/WearableDevice.swift`

`DeviceSettings` properties have default values (`autoConnect = true`, etc.), but the compiler-synthesized `init(from:)` calls `decode(_:forKey:)` (not `decodeIfPresent`) for every property. If any key is missing from the JSON payload, decoding throws a `keyNotFound` error and the entire decode fails. The default values are never consulted during decoding.

**Fix:** Implement custom `init(from:)` that uses `decodeIfPresent` with fallback to defaults.

---

### 9. Podfile — Unused dependencies

**File:** `ios_app/Podfile`

- `SwiftProtobuf` declared in all 3 targets but **never imported or used** anywhere in the codebase (all protobuf serialization is done via hand-written `ProtoCodec`).
- `Zip` declared but never imported or used.

**Fix:** Remove both unused pods from all targets.

---

### 10. MusicController.swift — Handlers return `.success` when `self` is nil

**File:** `ios_app/WearLink/Features/Music/MusicController.swift:73-91`

```swift
center.playCommand.addTarget { [weak self] _ in
    self?.onPlay?()
    return .success  // returns success even when self is nil
}
```

When `self` is nil the callback is a no-op, yet `.success` is returned. The system believes the command was handled when it was not.

**Fix:** Return `.noActionable` when `self` is nil:
```swift
center.playCommand.addTarget { [weak self] _ in
    guard let self else { return .noActionable }
    self.onPlay?()
    return .success
}
```

---

## iOS App — High Severity

### 11. BLEManager.swift — `onLinkControl` echoes wrong data

**File:** `ios_app/WearLink/BLE/BLEManager.swift:102`

The `onLinkControl` closure writes `frame.payload` — the *payload* of the received frame, not its sequence number. `GattClient.write(_:to:)` assigns a **new** `outSeq` to every outgoing frame, so the echoed frame carries a completely different sequence number than the one the watch sent. The watch cannot correlate the echo with its heartbeat.

**Fix:** Either encode `frame.seq` into the payload, or add a `writeAck(seq:)` method to `GattClient` that reuses the received seq.

---

### 12. NotificationForwarder.swift — Data loss on BLE write failure

**File:** `ios_app/WearLink/Features/Notification/NotificationForwarder.swift:213-228`

In `checkPendingNotifications()`, the pending notification is **cleared from UserDefaults before the BLE write**:

```swift
clearPendingNotification(defaults)   // data destroyed
registerNotificationActionHandler()
let payload = ProtoCodec.encodeWearNotification(wearNotif)
ble.gatt?.write(payload, to: WearLinkUUID.notification)  // may silently no-op
```

If `ble.gatt` is `nil` (watch not connected), the write silently does nothing via optional chaining, but the notification data is already gone from UserDefaults. The notification is permanently lost.

**Fix:** Clear pending data **after** successful write, or preserve data until delivery is confirmed.

---

### 13. CallController.swift — Missing `deinit` with `provider.invalidate()`

**File:** `ios_app/WearLink/Features/Call/CallController.swift`

`CXProvider` is never invalidated. Without this, the provider remains registered with the system until the process exits, even after the `CallController` is deallocated.

**Fix:** Add:
```swift
deinit { provider.invalidate() }
```

---

### 14. CallController.swift — `contactName(for:)` always returns nil

**File:** `ios_app/WearLink/Features/Call/CallController.swift:100-131`

`contactName(for:)` always returns `nil` because `CXCall` does not expose the remote handle (phone number) through its public API. The method requests contacts authorization for no benefit, which triggers an unnecessary system permission prompt.

**Fix:** Either remove the method entirely or implement the production approach (report the call via `CXProvider.reportNewIncomingCall` and extract the handle from `CXCallUpdate`).

---

### 15. Info.plist — Missing `CFBundleDevelopmentRegion`

**File:** `ios_app/WearLink/Resources/Info.plist`

Missing `CFBundleDevelopmentRegion` key. This is recommended for proper localization behavior.

**Fix:** Add `<key>CFBundleDevelopmentRegion</key><string>$(DEVELOPMENT_LANGUAGE)</string>`.

---

### 16. Info.plist — `audio` background mode may be unused

**File:** `ios_app/WearLink/Resources/Info.plist`

The `audio` background mode is declared but the app does not play audio itself — it sends play/pause/skip commands to the watch via BLE. Apple reviews background mode declarations and may reject the app if the mode is not actually used.

**Fix:** Remove `audio` from `UIBackgroundModes` if the app does not play background audio.

---

### 17. MusicController.swift — BLE handler registration fragile

**File:** `ios_app/WearLink/Features/Music/MusicController.swift:108`

If `ble.gatt` is `nil` at init time (BLE not yet connected), the handler is never registered. It only gets registered when `publishNowPlaying` is called for the first time. If the watch sends a `MusicCommand` before the app publishes any now-playing info, the command is silently dropped.

**Fix:** Add a dedicated reconnection/availability observer that registers the handler when `gatt` becomes non-nil.

---

### 18. MusicController.swift — Volume not clamped

**File:** `ios_app/WearLink/Features/Music/MusicController.swift:134`

```swift
case .setVolume:
    onChangeVolume?(command.volume)
```

The `onChangeVolume` callback contract says "0.0 - 1.0" but the incoming value is passed through without clamping. If the watch firmware sends an out-of-range value, it propagates unchecked to the audio system.

**Fix:** `onChangeVolume?(min(max(command.volume, 0), 1))`

---

### 19. MusicController.swift — `deinit` does not remove MPRemoteCommandCenter handlers

**File:** `ios_app/WearLink/Features/Music/MusicController.swift:62`

The five `addTarget` handlers registered on `MPRemoteCommandCenter.shared()` are never removed. If `MusicController` is deallocated, the command center retains handlers that weakly reference the now-deallocated object.

**Fix:** Store `addTarget` results and call `removeTarget(_:)` in `deinit`.

---

### 20. MusicController.swift — `togglePlayPauseCommand` not registered

**File:** `ios_app/WearLink/Features/Music/MusicController.swift:70-100`

Bluetooth accessories commonly send a play/pause *toggle* event rather than separate play and pause commands. Without registering `center.togglePlayPauseCommand`, these events are not handled.

**Fix:** Register `togglePlayPauseCommand` handler that toggles based on `nowPlaying.playing`.

---

## iOS App — Medium/Low

### 21. DevicesListView.swift — Eager destination creation via AnyView

**File:** `ios_app/WearLink/Views/Main/DevicesListView.swift:40-43`

`AnyView(HealthView())` evaluates `HealthView()` at the point the `FeatureCard` is initialized, not when the user taps the card. With `LazyVGrid` the cards themselves are created lazily, but the destination views are still created when each card appears.

**Fix:** Use `@ViewBuilder` generics or value-based navigation with `.navigationDestination(for:)` for true lazy creation.

---

### 22. ToggleRow.swift — Missing accessibility label

**File:** `ios_app/WearLink/Views/Common/ToggleRow.swift:27-28`

The `Toggle` is created with an empty label string `""` and `.labelsHidden()` is applied. The toggle has no accessibility label for VoiceOver users.

**Fix:** Add `.accessibilityLabel(title)` to the Toggle.

---

### 23. RootView.swift — Dead `container` property

**File:** `ios_app/WearLink/App/RootView.swift:4`

`RootView` declares `@Environment(AppContainer.self) private var container` but never references it in the body.

**Fix:** Remove the unused property.

---

### 24. AppContainer.swift — `ble.gatt?` optional chaining silently drops handler registration

**File:** `ios_app/WearLink/App/AppContainer.swift:45,49,53`

If `ble.gatt` is `nil` when `start()` runs, the assignment is silently skipped and the handlers are **never registered**.

**Fix:** Add guard + assertion: `guard let gatt = ble.gatt else { assertionFailure("gatt not ready"); return }`.

---

### 25. HealthViewModel.swift — Silent return when HealthKit unavailable

**File:** `ios_app/WearLink/Features/Health/HealthViewModel.swift:26-30`

The method is declared `async throws`, but when `isHealthDataAvailable()` is `false` it returns normally instead of throwing. A caller using `try await` will not get an error on this path.

**Fix:** Throw a meaningful error (e.g., `HKError(.errorHealthDataUnavailable)` or a custom `HealthError`).

---

### 26. HealthViewModel.swift — `@ObservationIgnored` missing on private buffer

**File:** `ios_app/WearLink/Features/Health/HealthViewModel.swift:11`

`private var pending: [HKSample] = []` is tracked by the observation system even though no UI code can read this property.

**Fix:** Add `@ObservationIgnored` attribute.

---

### 27. ProtoSerialization.swift — `skipField` silently accepts truncated data

**File:** `ios_app/WearLink/BLE/ProtoSerialization.swift:182,185,187`

For wire types 1, 2, and 5, if the remaining data is shorter than expected, `offset` is silently clamped to `data.count` rather than signalling an error. Corruption in unknown fields is invisible to callers.

**Fix:** Check bounds before advancing and propagate failure.

---

### 28. ProtoSerialization.swift — `try?` on non-throwing functions

**File:** `ios_app/WearLink/BLE/ProtoSerialization.swift:180,184`

`decodeVarint` returns `UInt64?` — it does not throw. The `try?` is a no-op and misleading.

**Fix:** Remove `try?`.

---

### 29. ProtoSerialization.swift — Inconsistent packed/unpacked enum error handling

**File:** `ios_app/WearLink/BLE/ProtoSerialization.swift:462-477`

In `decodeHealthControl`, the unpacked repeated enum case returns `nil` on an invalid enum value, failing the entire decode. The packed case uses `break` instead, silently dropping the rest of the packed data.

**Fix:** Make both paths consistent.

---

### 30. GattClient.swift — Error parameters silently ignored

**File:** `ios_app/WearLink/BLE/GattClient.swift:26,31,65`

In all three delegate callbacks (`didDiscoverServices`, `didDiscoverCharacteristicsFor`, `didUpdateValueFor`), the `error: Error?` parameter is never inspected or logged.

**Fix:** Log the error in each callback before returning.

---

### 31. GattClient.swift — No write-type capability check

**File:** `ios_app/WearLink/BLE/GattClient.swift:49`

`write()` never checks `c.properties.contains(.write)` (for `.withResponse`) or `.writeWithoutResponse`. If the characteristic only supports notify, the write silently fails.

**Fix:** Add a property check and return early if the write type is unsupported.

---

### 32. GattClient.swift — No connected-state check before writeValue

**File:** `ios_app/WearLink/BLE/GattClient.swift:60`

`peripheral.writeValue(frame, for: c, type: type)` is called without checking `peripheral.state == .connected`. If the peripheral disconnects between the guard and the write, the write is silently dropped.

**Fix:** Add `guard peripheral.state == .connected else { return }` before the write loop.

---

### 33. BLEManager.swift — Redundant `Task { @MainActor in }` in onPayload closures

**File:** `ios_app/WearLink/BLE/BLEManager.swift:108-122`

`CBCentralManager` was created with `queue: .main`, so all `CBPeripheralDelegate` callbacks already execute on the main queue. The `Task { @MainActor in }` hop is unnecessary.

**Fix:** Remove the `Task { @MainActor in }` wrapper.

---

### 34. BLEManager.swift — `peripheral.delegate = self` is dead code

**File:** `ios_app/WearLink/BLE/BLEManager.swift:90`

`BLEManager` conforms to `CBPeripheralDelegate` but implements **none** of its methods. The delegate is immediately replaced by `GattClient` in `didConnect`.

**Fix:** Remove line 90 and the empty `CBPeripheralDelegate` conformance.

---

### 35. CallController.swift — `CXProviderConfiguration()` deprecated

**File:** `ios_app/WearLink/Features/Call/CallController.swift:30`

`CXProviderConfiguration()` uses the deprecated convenience initializer. The designated initializer is `CXProviderConfiguration(localizedName:)`.

**Fix:** Use `CXProviderConfiguration(localizedName: "WearLink")`.

---

### 36. CallController.swift — `providerDidReset` does not clear all state

**File:** `ios_app/WearLink/Features/Call/CallController.swift:176-179`

`providerDidReset` clears `activeCallIDs` but does not reset `hasIncomingCall` or `incomingCallerName`. If the provider resets, the UI will still show stale incoming-call state.

**Fix:** Reset `hasIncomingCall` and `incomingCallerName` in `providerDidReset`.

---

### 37. DeviceCardView.swift — Battery threshold uses `>` not `>=`

**File:** `ios_app/WearLink/Views/Main/DeviceCardView.swift:30,33`

`batteryLevel > 20 ? .green : .red` — using `>` means a battery at exactly 20% is rendered red (low). The conventional threshold is "below 20%".

**Fix:** Change to `batteryLevel >= 20` or `batteryLevel < 20 ? .red : .green`.

---

## Wear OS App — Critical Issues

### 38. AncsClient.kt — BufferOverflowException

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/AncsClient.kt:220`

```kotlin
val request = ByteBuffer.allocate(8)  // BUG: should be 9
request.put(0)                        // 1 byte  CommandID
request.putInt(uid)                   // 4 bytes NotificationUID
request.put(0)                        // 1 byte  AppIdentifier
request.put(1)                        // 1 byte  Title
request.put(3)                        // 1 byte  Message
request.put(5)                        // 1 byte  Date
// Total: 1 + 4 + 4 = 9 bytes
```

The `ByteBuffer` is allocated with capacity 8 but 9 bytes are written. This will throw `java.nio.BufferOverflowException` the first time a notification arrives and `requestNotificationAttributes` is called.

**Fix:** `ByteBuffer.allocate(9)`.

---

### 39. HealthCollector.kt — Executor shutdown permanently kills thread pool

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/HealthCollector.kt:75`

```kotlin
fun stop() {
    unregisterPassive()
    stopActive()
    executor.shutdown()   // single-use executor
}
```

`Executors.newSingleThreadExecutor()` returns an executor that cannot be restarted after `shutdown()`. If `start()` is called again (e.g., Flutter hot restart, or the plugin detaches and re-attaches), the executor is dead and all callbacks silently fail.

**Fix:** Either do not shut down the executor in `stop()`, or recreate it in `start()`.

---

### 40. AndroidManifest.xml — Missing Health Services permissions

**File:** `wear_app/android/app/src/main/AndroidManifest.xml`

The app uses `androidx.health.services.client.HealthServices` API in `HealthCollector.kt` to read heart rate, steps, calories, distance, and sleep data. However, the manifest only declares `BODY_SENSORS` and `ACTIVITY_RECOGNITION`, which are permissions for the legacy Android Sensor API, **not** the Health Services API.

The Health Services API requires its own set of runtime permissions:
- `android.permission.health.READ_HEART_RATE`
- `android.permission.health.READ_STEPS`
- `android.permission.health.READ_DISTANCE`
- `android.permission.health.READ_CALORIES`
- `android.permission.health.READ_SLEEP`

Without these, `HealthCollector` will throw a `SecurityException` at runtime.

**Fix:** Add all required health permissions to the manifest.

---

### 41. AndroidManifest.xml — Missing `bluetooth_le` feature declaration

**File:** `wear_app/android/app/src/main/AndroidManifest.xml`

The app is a BLE peripheral (advertiser + GATT server) but does not declare that BLE hardware is required. Without this, the app could be installed on a Wear OS device that lacks BLE support.

**Fix:** Add `<uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />`.

---

## Wear OS App — High Severity

### 42. AncsClient.kt — Scanning by device name is unreliable

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/AncsClient.kt:82`

```kotlin
if (device.name?.contains("iPhone") == true || device.name?.contains("iOS") == true)
```

Device names can be empty during BLE scanning, and many iOS devices have custom names.

**Fix:** Use a `ScanFilter` with the ANCS service UUID (`7905F431-B5CE-4E99-A40F-4B1E122D00D0`) instead of relying on the device name.

---

### 43. AncsClient.kt — No runtime permission checks for Android 12+

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/AncsClient.kt`

On Android 12 (API 31+), `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` are runtime permissions. The code calls `startScan()` and `connectGatt()` without checking or requesting these permissions.

**Fix:** Add permission checks and requests for `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` on API 31+.

---

### 44. AncsClient.kt — Date parsing is fragile

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/AncsClient.kt:270-271`

```kotlin
val sdf = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US)
val date = sdf.parse(value.take(19))
```

iOS may send dates with timezone offsets (e.g., `2024-01-15T14:30:00+05:00`). The `.take(19)` truncates the timezone, so the parsed time is treated as local time rather than UTC, producing an incorrect timestamp.

**Fix:** Parse full ISO 8601 string with timezone handling.

---

### 45. BlePeripheralService.kt — `notifying` set is not thread-safe

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/BlePeripheralService.kt`

`notifying` is a plain `mutableSetOf<UUID>()`. It is mutated on the Binder thread and read on the main thread. This is a data race.

**Fix:** Use `Collections.synchronizedSet(mutableSetOf())` or `ConcurrentHashMap.newKeySet()`.

---

### 46. BlePeripheralService.kt — `onMtuChanged` is a no-op

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/BlePeripheralService.kt:155-157`

The phone may request an MTU up to 512 bytes. The watch never learns about it, so `notify()` will send frames at the default MTU (23 bytes). If the Dart codec produces frames larger than 23 bytes, they will be silently truncated.

**Fix:** Surface MTU change to the plugin and adjust frame sizes accordingly.

---

### 47. BlePeripheralService.kt — All characteristics get READ + WRITE permissions

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/BlePeripheralService.kt:96-97`

Even characteristics that are write-only (like `callAction`, `notificationAction`, `musicCommand`) have `PERMISSION_READ`. This is unnecessary and exposes data that should not be readable.

**Fix:** Return separate permissions per characteristic based on its properties.

---

### 48. HealthCollector.kt — No BODY_SENSORS permission check

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/HealthCollector.kt`

`registerPassive()` will silently fail (caught by the generic `try/catch`) if `BODY_SENSORS` permission is not granted. The caller has no way to distinguish "permission denied" from "Bluetooth off".

**Fix:** Check `ContextCompat.checkSelfPermission` before starting.

---

### 49. HealthCollector.kt — `bootInstant()` has a race condition

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/HealthCollector.kt:191-192`

```kotlin
private fun bootInstant(): Instant =
    Instant.now().minus(Duration.ofMillis(SystemClock.elapsedRealtime()))
```

If the system clock is adjusted between `Instant.now()` and `SystemClock.elapsedRealtime()`, the computed boot instant will be wrong, causing all health data timestamps to be shifted.

**Fix:** Compute once and cache, or use `SystemClock.currentNetworkTimeClock()`.

---

### 50. HealthCollector.kt — `clearPassiveListenerCallbackAsync()` is too broad

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/HealthCollector.kt:134`

This clears ALL passive listeners, not just this collector's. If any other component registered a passive listener, it would be removed.

**Fix:** Use a more targeted removal approach.

---

### 51. AncsClient.kt — CCCD writes are not verified

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/AncsClient.kt:156-172`

The code writes CCCD descriptors for Notification Source and Data Source but never checks the result. If the descriptor write fails, notifications will never arrive and there is no error path.

**Fix:** Check the result of descriptor writes and surface errors.

---

### 52. BlePeripheralService.kt — `start()` has no failure feedback

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/BlePeripheralService.kt:44-49`

If Bluetooth is off, `adapter` is null, `server` is null, and `start()` returns successfully. The caller has no way to know the service is not running.

**Fix:** Check `adapter?.isEnabled` and/or `server != null` and surface the failure.

---

## Wear OS App — Medium/Low

### 53. pubspec.yaml — Missing Flutter SDK constraint

**File:** `wear_app/pubspec.yaml`

The `environment` section only constrains the Dart SDK. There is no `flutter:` entry.

**Fix:** Add `flutter: ">=3.22.0"`.

---

### 54. pubspec.yaml — `cupertino_icons` unused

**File:** `wear_app/pubspec.yaml`

`cupertino_icons: ^1.0.8` is declared but never imported in any Dart source file.

**Fix:** Remove the dependency.

---

### 55. pubspec.yaml — Outdated dependencies

**File:** `wear_app/pubspec.yaml`

- `protobuf: ^3.1.0` (latest: 6.0.0)
- `signals: ^6.0.0` (latest: 7.1.0)
- `protoc_plugin: ^21.1.0` (latest: 25.0.0)

**Fix:** Review changelogs and bump constraints, then regenerate protobuf Dart code.

---

### 56. build.gradle.kts — Kotlin version may conflict with Flutter

**File:** `wear_app/android/settings.gradle.kts:23`

Kotlin version `2.3.20` is ahead of Flutter's own Kotlin version (`2.2.20`). Using a Kotlin version newer than what Flutter's own build tooling uses risks incompatibility.

**Fix:** Match Flutter's expected Kotlin version (`2.2.20`).

---

### 57. build.gradle.kts — Health Services dependency pinned to RC

**File:** `wear_app/android/app/build.gradle.kts:43`

`health-services-client:1.1.0-rc02` pins a release candidate. For production, use a stable release.

**Fix:** Update to latest stable version (e.g., `1.1.0`).

---

### 58. Dart platform channels — Event channel subscriptions never cancelable

**Files:** `wear_app/lib/platform/ancs_channel.dart:20`, `health_services_channel.dart:20`

Both constructors call `_eventChannel.receiveBroadcastStream().listen(...)` but **never store the returned `StreamSubscription`**. The `dispose()` methods close the `StreamController` but do not cancel the event channel subscription.

**Fix:** Store the subscription and cancel it in `dispose()`.

---

### 59. Dart — Missing explicit `dart:typed_data` import

**File:** `wear_app/lib/platform/ble_peripheral_channel.dart`

The file uses `Uint8List` but only imports `dart:async` and `package:flutter/services.dart`. It relies on a transitive re-export.

**Fix:** Add `import 'dart:typed_data';`.

---

### 60. AndroidManifest.xml — `taskAffinity=""` on MainActivity

**File:** `wear_app/android/app/src/main/AndroidManifest.xml`

Setting `taskAffinity` to an empty string means the activity has no task affinity, causing it to always launch in a new task stack. This is non-standard for a launcher activity.

**Fix:** Remove the `taskAffinity` line entirely.

---

### 61. AndroidManifest.xml — Unnecessary `BLUETOOTH_SCAN` permission

**File:** `wear_app/android/app/src/main/AndroidManifest.xml`

The app is a BLE peripheral only (advertiser + GATT server). It never scans for devices. This permission is unused.

**Fix:** Remove `BLUETOOTH_SCAN` permission.

---

### 62. AndroidManifest.xml — Missing `POST_NOTIFICATIONS` permission

**File:** `wear_app/android/app/src/main/AndroidManifest.xml`

On Android 13+ (API 33+), apps must declare and request this permission to post notifications.

**Fix:** Add `POST_NOTIFICATIONS` permission.

---

### 63. BlePeripheralService.kt — CCCD UUID compared as string

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/BlePeripheralService.kt:191-192`

```kotlin
if (descriptor.uuid.toString()
        .equals("00002902-0000-1000-8000-00805F9B34FB", ignoreCase = true))
```

**Fix:** Use `UUID.fromString("00002902-...")` and compare with `descriptor.uuid == cccdUuid`.

---

### 64. BlePeripheralService.kt — `onCharacteristicReadRequest` returns wrong error code

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/BlePeripheralService.kt:169`

If a central reads any characteristic other than `deviceInfo`, it gets an empty response with `GATT_SUCCESS`. The spec says reading an unsupported characteristic should return `GATT_READ_NOT_PERMITTED` (0x02).

**Fix:** Return `GATT_READ_NOT_PERMITTED` for unsupported reads.

---

### 65. AncsClient.kt — Mutable state on Binder thread

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/AncsClient.kt:192,242`

`pendingNotificationUid` and `pendingNotif` are mutated directly in GATT callbacks. If a second "Added" event arrives before the first notification's attributes are fully fetched, `pendingNotificationUid` is silently overwritten.

**Fix:** Use a queue/Map keyed by UID instead of a single mutable slot.

---

### 66. Uuids.kt — Placeholder UUID base

**File:** `wear_app/android/app/src/main/kotlin/com/wearlink/app/Uuids.kt:8`

The comment acknowledges this: "TODO before ship: generate a random 128-bit base." Using the Bluetooth SIG base UUID with 16-bit handles risks collision with real SIG-assigned UUIDs in production.

**Fix:** Generate a random 128-bit UUID base before production release.

---

## CI/CD Issues

### 67. build-ios.yml — Signed archive step missing explicit signing configuration

**File:** `.github/workflows/build-ios.yml:117-124`

The signed build step passes only `-developmentTeam "$TEAM_ID"` to `xcodebuild archive`. It does **not** set `CODE_SIGN_STYLE=Manual` or `PROVISIONING_PROFILE_SPECIFIER=build`.

**Fix:** Add:
```
CODE_SIGN_STYLE=Manual \
PROVISIONING_PROFILE_SPECIFIER=build \
```

---

### 68. build-ios.yml — Hardcoded bundle ID in ExportOptions.plist

**File:** `.github/workflows/build-ios.yml:134`

The `ExportOptions.plist` hardcodes `com.wearlink.app` as the bundle identifier in the `provisioningProfiles` dictionary.

**Fix:** Derive from project or set via a secret/variable.

---

### 69. build-ios.yml — Test destination simulator name may not match

**File:** `.github/workflows/build-ios.yml:67`

Uses `name=iPhone 16`. Depending on the exact Xcode 16.x version installed on the runner, the simulator name could be "iPhone 16", "iPhone 16 Pro", or another variant.

**Fix:** Use a more robust destination specifier or query available simulators first.

---

### 70. build-ios.yml — `setup-xcode` pinned to mutable `@v1` tag

**File:** `.github/workflows/build-ios.yml:32`

`@v1` tag tracks the latest v1.x release, which can introduce breaking changes unexpectedly.

**Fix:** Pin to a specific release, e.g. `@v1.6.0`.

---

### 71. build-ios.yml — Xcode version `"16"` may select a beta

**File:** `.github/workflows/build-ios.yml:34`

If the runner has both a stable Xcode 16.x and a beta 16.x installed, the action selects the latest matching version, which could be a beta.

**Fix:** Specify a concrete stable version like `"16.0"` or `"16.2"`.

---

## Full Review Details

### iOS App — DevicesListView.swift

**File:** `ios_app/WearLink/Views/Main/DevicesListView.swift`

**Status:** Mostly correct

| Check | Result |
|-------|--------|
| NavigationStack usage | ✅ Correct |
| @Environment(AppContainer.self) | ✅ Correct |
| Missing imports | ✅ None |
| FeatureCard NavigationLink destinations | ⚠️ Eager creation via AnyView |
| Retain cycles / memory leaks | ✅ None |
| Preview code | ✅ Valid |

**Issues:**
- Lines 40-43: `AnyView(HealthView())` evaluates destination views eagerly when each `FeatureCard` appears, not when the user taps. Use `@ViewBuilder` generics or value-based navigation for lazy creation.
- Line 97: `AnyView` type-erasure defeats SwiftUI structural identity and adds runtime overhead.

---

### iOS App — ToggleRow.swift

**File:** `ios_app/WearLink/Views/Common/ToggleRow.swift`

**Status:** Correct, one accessibility issue

| Check | Result |
|-------|--------|
| @Binding usage | ✅ Correct |
| Optional Image? handling | ✅ Safe |
| Toggle .tint(.green) | ✅ Works on iOS 17+ |
| Layout | ✅ Correct |

**Issues:**
- Lines 27-28: Missing accessibility label for VoiceOver. Add `.accessibilityLabel(title)` to the Toggle.

---

### iOS App — DeviceDetailsView.swift

**File:** `ios_app/WearLink/Views/DeviceDetails/DeviceDetailsView.swift`

**Status:** Correct

| Check | Result |
|-------|--------|
| Binding(get:set:) with @Observable | ✅ Correct |
| SectionHeader usage | ✅ Correct |
| ToggleRow bindings | ✅ Correct |
| NavigationLink to DeviceInfoSection | ✅ Correct |
| Missing imports | ✅ None |

**Note:** `DeviceSettings` is a plain struct (not `@Observable`), so changing any single field replaces the entire struct. This means any view that reads *any* property of `container.settings` will be invalidated when *any* field changes. Performance observation, not a correctness bug.

---

### iOS App — MusicControlOptionsView.swift

**File:** `ios_app/WearLink/Views/Music/MusicControlOptionsView.swift`

**Status:** Correct

| Check | Result |
|-------|--------|
| Picker with enum BackgroundColor | ✅ Correct |
| ToggleRow bindings | ✅ Correct |
| SectionHeader usage | ✅ Correct |
| Missing imports | ✅ None |

---

### iOS App — DeviceCardView.swift

**File:** `ios_app/WearLink/Views/Main/DeviceCardView.swift`

**Status:** One bug found

| Check | Result |
|-------|--------|
| DeviceIconView usage | ✅ Correct |
| Battery level color logic | ⚠️ Bug |
| Connection status dot | ✅ Correct |
| Shadow + cornerRadius | ✅ Correct |

**Issues:**
- Line 28: Battery icon hardcoded to `"battery.75"` regardless of `batteryLevel`. Should dynamically select SF Symbol based on actual level.
- Lines 30, 33: Threshold `> 20` treats exactly 20% as low; conventional threshold is `batteryLevel < 20` (or `<= 20`).

---

### iOS App — RootView.swift

**File:** `ios_app/WearLink/App/RootView.swift`

**Status:** Correct, dead code

| Check | Result |
|-------|--------|
| DevicesListView() as root | ✅ Correct |
| @Environment usage | ✅ Correct |
| Missing imports | ✅ None |

**Issues:**
- Line 4: Unused `container` property — never referenced in the body. Remove for clarity.

---

### iOS App — AppContainer.swift

**File:** `ios_app/WearLink/App/AppContainer.swift`

**Status:** Correct, minor concerns

| Check | Result |
|-------|--------|
| @Observable macro | ✅ Correct |
| device + settings properties | ✅ Correct |
| HealthKit do-catch | ✅ Correct (minor logging issue) |
| BLE onPayload handlers | ⚠️ Optional chaining may silently drop |
| Retain cycles | ✅ None |

**Issues:**
- Lines 45, 49, 53: `ble.gatt?` optional chaining silently drops handler registration if `gatt` is nil at `start()` time.
- Line 64: `error.localizedDescription` strips diagnostic detail; prefer `\(error)` for logging.

---

### iOS App — Models/WearableDevice.swift

**File:** `ios_app/WearLink/Models/WearableDevice.swift`

**Status:** One Codable bug

| Check | Result |
|-------|--------|
| Identifiable conformance | ✅ Correct |
| Codable conformance | ⚠️ Bug in DeviceSettings |
| Default values | ✅ Reasonable |

**Issues:**
- `DeviceSettings` uses compiler-synthesized `init(from:)` which calls `decode(_:forKey:)` (not `decodeIfPresent`). If any key is missing from JSON, decoding throws `keyNotFound`. Default values are never consulted during decoding.

---

### iOS App — BLEManager.swift

**File:** `ios_app/WearLink/BLE/BLEManager.swift`

**Status:** Multiple issues

| Check | Result |
|-------|--------|
| CBCentralManagerDelegate | ⚠️ State not updated on Bluetooth off |
| Duty-cycled scan | ✅ Correct |
| Heartbeat timer | ⚠️ Echoes wrong data |
| State machine transitions | ⚠️ Missing state updates |
| Threading | ⚠️ Several issues |

**Issues:**
1. Line 77: State not updated to `.poweredOff` when Bluetooth turns off.
2. Line 102: `onLinkControl` echoes `frame.payload` instead of the sequence number; `GattClient.write` assigns a new seq, so the watch cannot correlate the ACK.
3. Lines 100-103: `onLinkControl` accesses `@MainActor` `self` from non-isolated closure without a concurrency hop.
4. Lines 108-122: `onPayload` closures use redundant `Task { @MainActor in }` — already on main queue.
5. Line 90: `peripheral.delegate = self` is dead code (no `CBPeripheralDelegate` methods implemented).
6. Lines 98 vs 126: `peripheral.delegate = client` set before handlers are configured — latent ordering fragility.
7. Lines 95-96: Non-Sendable `CBPeripheral` captured across concurrency boundary (Swift 6 strict concurrency).

---

### iOS App — GattClient.swift

**File:** `ios_app/WearLink/BLE/GattClient.swift`

**Status:** Critical issues found

| Check | Result |
|-------|--------|
| CBPeripheralDelegate | ⚠️ Issues |
| Service discovery | ⚠️ Error params ignored |
| onPayload dispatch | ⚠️ Single reassembler |
| write() method | ⚠️ No capability check |
| Reassembly | ⚠️ Perf-characteristic needed |

**Issues:**
1. **Critical** Line 10: Single `Reassembler` shared across characteristics — chunk interleaving.
2. Medium Lines 17-20: `peripheral.delegate` not set in `init`.
3. Medium Lines 26, 31, 65: Error parameters silently ignored.
4. Medium Line 49: No write-type capability check in `write()`.
5. Low Line 50: Unnecessary `UInt16` cast.
6. Low Line 60: No connected-state check before `writeValue`.
7. Low Lines 11, 52-53: `outSeq` not thread-safe.

---

### iOS App — ProtoSerialization.swift

**File:** `ios_app/WearLink/BLE/ProtoSerialization.swift`

**Status:** Issues found

| Check | Result |
|-------|--------|
| Varint encoding | ✅ Correct |
| Varint decoding | ⚠️ Overflow check off by one |
| Wire type handling | ⚠️ Truncation in skipField |
| Message type coverage | ✅ All 11 types covered |
| Buffer overruns | ⚠️ Latent issues |

**Issues:**
1. **High** Line 38: Varint overflow check off by one; `UInt64(byte) << 63` traps when byte >= 2.
2. Medium Lines 182,185,187: `skipField` silently clamps offset on truncated data, hiding corruption.
3. Low Lines 180,184: `try?` on non-throwing `decodeVarint` is misleading.
4. Low Lines 462-477: Packed vs unpacked enum error handling is inconsistent.
5. Low Line 101: `Int(len)` truncation on 32-bit platforms (latent).

---

### iOS App — PacketCodec.swift

**File:** `ios_app/WearLink/BLE/PacketCodec.swift`

**Status:** Correct — no issues found

| Check | Result |
|-------|--------|
| Frame encoding/decoding | ✅ Correct, matches Dart |
| CRC-8 algorithm | ✅ Correct, matches Dart |
| Reassembler logic | ✅ Correct, matches Dart |
| Edge cases | ✅ All handled |

---

### iOS App — CallController.swift

**File:** `ios_app/WearLink/Features/Call/CallController.swift`

**Status:** Multiple issues

| Check | Result |
|-------|--------|
| CXCallObserverDelegate | ✅ Correct |
| CXProvider setup | ⚠️ Deprecated initializer |
| Contact resolution | ⚠️ Dead code, always returns nil |
| BLE handler registration | ⚠️ Fragile |
| Threading | ✅ Safe |

**Issues:**
1. High: Missing `deinit` with `provider.invalidate()` — resource leak.
2. Medium Lines 100-131: `contactName(for:)` always returns nil; dead code that requests contacts permission.
3. Medium Lines 44,74: BLE handler registration is fragile; no registration when gatt connects after init.
4. Medium Lines 176-179: `providerDidReset` does not clear `hasIncomingCall`/`incomingCallerName`.
5. Low Line 30: `CXProviderConfiguration()` deprecated; use `init(localizedName:)`.
6. Low Line 182: `CXAnswerCallAction.fulfill()` without audio session configuration.

---

### iOS App — HealthViewModel.swift

**File:** `ios_app/WearLink/Features/Health/HealthViewModel.swift`

**Status:** Minor issues

| Check | Result |
|-------|--------|
| isHealthDataAvailable() check | ⚠️ Silent return, inconsistent with throws |
| HealthKit authorization | ✅ Correct |
| Error handling | ⚠️ Minor |
| @Observable usage | ⚠️ Missing @ObservationIgnored |

**Issues:**
1. Medium Lines 26-30: Silent return on unavailable HealthKit (inconsistent with `throws`).
2. Low Line 11: `@ObservationIgnored` missing on private buffer.

---

### iOS App — MusicController.swift

**File:** `ios_app/WearLink/Features/Music/MusicController.swift`

**Status:** 8 issues found

| Check | Result |
|-------|--------|
| MPRemoteCommandCenter | ⚠️ Returns .success when self is nil |
| NowPlaying info center | ✅ Correct |
| BLE command dispatch | ⚠️ Fragile registration |
| Timer management | ⚠️ Missing cleanup |
| Volume range | ⚠️ Not clamped |

**Issues:**
1. Lines 73-91: Handlers return `.success` when `self` is nil.
2. Line 108: BLE handler never registered if `gatt` is nil at init.
3. Line 166: `registerCommandHandler()` called on every `publishNowPlaying` — wasteful.
4. No reconnection handling — orphaned handler on old `GattClient`.
5. Line 134: Volume not clamped.
6. Line 34: Default volume is 0 — watch shows zero until first explicit publish.
7. Line 62: `deinit` does not remove MPRemoteCommandCenter handlers.
8. Missing: `togglePlayPauseCommand` not registered.

---

### iOS App — NotificationForwarder.swift

**File:** `ios_app/WearLink/Features/Notification/NotificationForwarder.swift`

**Status:** Critical issues found

| Check | Result |
|-------|--------|
| App group bridge | ❌ Missing entitlement |
| Darwin notification callback | ⚠️ Fragile C function pointer |
| BLE handler registration | ⚠️ Redundant registration |
| encodeWearNotification name | ✅ Correct |
| Threading | ⚠️ Data loss on write failure |

**Issues:**
1. **Critical** Lines 11, entitlements: App group entitlement missing in both targets; `UserDefaults(suiteName:)` silently fails.
2. **High** Lines 213-228: Data loss — pending notification cleared from UserDefaults before BLE write.
3. Moderate Line 275: `CFNotificationCallback` stored as a closure variable instead of `@convention(c)` global function.
4. Moderate BLEManager.swift:112-117: Redundant `notificationAction` handler registration.
5. Low Lines 125-132: `forwardedNotifications` populated even when BLE write silently no-ops.

---

### iOS App — Info.plist

**File:** `ios_app/WearLink/Resources/Info.plist`

**Status:** Minor issues

| Check | Result |
|-------|--------|
| Required keys | ⚠️ Missing CFBundleDevelopmentRegion |
| Background modes | ⚠️ audio may be unused |
| Usage descriptions | ✅ All present |
| Bundle identifiers | ✅ Match project.yml |
| iOS 17+ keys | ✅ Correct |

**Issues:**
1. Medium: Missing `CFBundleDevelopmentRegion`.
2. High: `audio` background mode may be unused — App Store rejection risk.
3. Medium: Missing `remote-notification` background mode if main app needs silent push.

---

### iOS App — WearLink.entitlements

**File:** `ios_app/WearLink/Resources/WearLink.entitlements`

**Status:** Critical issues

| Check | Result |
|-------|--------|
| HealthKit | ✅ Correct |
| App Groups | ❌ Missing |
| aps-environment | ❌ Missing |
| BLE background | ✅ Correct (via Info.plist) |

**Issues:**
1. **Critical**: Missing `com.apple.security.application-groups` — app-group bridge will fail at runtime.
2. **High**: Missing `aps-environment` — push notifications won't reach the app or its service extension.

---

### iOS App — project.yml

**File:** `ios_app/project.yml`

**Status:** Correct

| Check | Result |
|-------|--------|
| XcodeGen config | ✅ Valid |
| All targets | ✅ Correct |
| Source paths include Views/Models | ✅ Auto-included via recursive `WearLink` path |
| Dependencies | ✅ Correct |
| Deployment target | ✅ iOS 17.0 |
| Bundle identifiers | ✅ Match entitlements |

**Minor:**
- Redundant `INFOPLIST_FILE` in WearLink target settings.
- Empty `DEVELOPMENT_TEAM` — prevents device builds until set.
- NotificationServiceExtension entitlements are a stub.

---

### iOS App — Podfile

**File:** `ios_app/Podfile`

**Status:** Unused dependencies

| Check | Result |
|-------|--------|
| SwiftProtobuf version | ❌ Unused in all 3 targets |
| Zip dependency | ❌ Unused |
| Post-install script | ⚠️ Redundant |
| Platform iOS 17.0 | ✅ Correct |
| NotificationServiceExtension | ✅ Structurally correct |

**Issues:**
1. `SwiftProtobuf` pod declared in all 3 targets but never imported or used.
2. `Zip` pod declared but never imported or used.
3. Post-install script manually sets `IPHONEOS_DEPLOYMENT_TARGET` to '17.0', which is already handled by the `platform` directive.

---

### Wear OS App — Dart/Flutter (15 files)

**Files Reviewed:**
- `main.dart` (265 lines)
- `ble/gatt_client.dart` (105 lines)
- `ble/packet_codec.dart` (104 lines)
- `features/call/call_screen.dart` (361 lines)
- `features/health/health_screen.dart` (114 lines)
- `features/music/music_screen.dart` (418 lines)
- `features/notification/notification_screen.dart` (270 lines)
- `platform/ancs_channel.dart` (40 lines)
- `platform/ble_peripheral_channel.dart` (61 lines)
- `platform/health_services_channel.dart` (46 lines)
- `signals/ble_signal.dart` (19 lines)
- `signals/call_signal.dart` (129 lines)
- `signals/health_signal.dart` (124 lines)
- `signals/music_signal.dart` (152 lines)
- `signals/notification_signal.dart` (136 lines)

**Issues:**
1. **Medium** `ble_peripheral_channel.dart`: Missing explicit `dart:typed_data` import for `Uint8List`.
2. **Medium** `ancs_channel.dart` and `health_services_channel.dart`: Event channel subscriptions never cancelable — memory leak.
3. **Low** `health_screen.dart`: `theme.textTheme.bodySmall` used without null-aware access.
4. **Low** `call_screen.dart`: `_CallTimer` Stopwatch never reset.
5. **Low** `notification_screen.dart`: `_appColor` uses `hashCode` which is not stable across runs.

**No issues found in:** `ble_signal.dart`, `call_signal.dart`, `health_signal.dart`, `music_signal.dart`, `notification_signal.dart`, `gatt_client.dart`, `packet_codec.dart`.

---

### Wear OS App — Kotlin (8 files)

**Files Reviewed:**
- `Uuids.kt` (29 lines)
- `BlePeripheralService.kt` (214 lines)
- `AncsClient.kt` (288 lines)
- `AncsPlugin.kt` (76 lines)
- `HealthCollector.kt` (193 lines)
- `HealthServicesPlugin.kt` (76 lines)
- `MainActivity.kt` (14 lines)
- `WearLinkBlePlugin.kt` (81 lines)

**Issues:**
1. **Critical** `AncsClient.kt:220`: `ByteBuffer.allocate(8)` but writes 9 bytes → `BufferOverflowException`.
2. **Critical** `HealthCollector.kt:75`: `executor.shutdown()` permanently kills thread pool; can't restart.
3. **Threading** `BlePeripheralService.kt`: `notifying` set not thread-safe.
4. **Threading** `AncsClient.kt`: Mutable state on Binder thread — single mutable slot overwritten.
5. **Functional** `BlePeripheralService.kt:155-157`: `onMtuChanged` is a no-op.
6. **Functional** `BlePeripheralService.kt:44-49`: `start()` has no failure feedback.
7. **Functional** `BlePeripheralService.kt:96-97`: All characteristics get READ + WRITE permissions.
8. **Functional** `AncsClient.kt:82`: Scanning by device name is unreliable.
9. **Functional** `AncsClient.kt`: No runtime permission checks for Android 12+.
10. **Functional** `AncsClient.kt:270-271`: Date parsing is fragile — timezone truncation.
11. **Functional** `AncsClient.kt:156-172`: CCCD writes are not verified.
12. **Design** `HealthCollector.kt`: No BODY_SENSORS permission check.
13. **Design** `HealthCollector.kt:191-192`: `bootInstant()` has a race condition.
14. **Design** `HealthCollector.kt:134`: `clearPassiveListenerCallbackAsync()` is too broad.
15. **Minor** `BlePeripheralService.kt:191-192`: CCCD UUID compared as string.
16. **Minor** `BlePeripheralService.kt:169`: Wrong GATT error code for unsupported reads.
17. **Minor** `Uuids.kt:8`: Placeholder UUID base — risk of collision.

**No issues in:** `AncsPlugin.kt`, `HealthServicesPlugin.kt`, `WearLinkBlePlugin.kt`, `MainActivity.kt`.

---

### Wear OS App — pubspec.yaml

**File:** `wear_app/pubspec.yaml`

**Issues:**
1. **Medium**: Missing Flutter SDK constraint.
2. **Low**: `cupertino_icons` unused.
3. **Medium**: Outdated dependencies (`protobuf: ^3.1.0`, `signals: ^6.0.0`, `protoc_plugin: ^21.1.0`).

---

### Wear OS App — AndroidManifest.xml

**File:** `wear_app/android/app/src/main/AndroidManifest.xml`

**Issues:**
1. **Critical**: Missing Health Services API permissions (`health.READ_*`).
2. **High**: Missing `android.hardware.bluetooth_le` feature declaration.
3. **Medium**: `taskAffinity=""` on `MainActivity` causes unusual task behavior.
4. **Low**: Unnecessary `BLUETOOTH_SCAN` permission.
5. **Low**: Missing `POST_NOTIFICATIONS` permission for Android 13+.

---

### Wear OS App — build.gradle.kts

**File:** `wear_app/android/app/build.gradle.kts`

**Issues:**
1. **Medium**: Kotlin version `2.3.20` is ahead of Flutter's own Kotlin version (`2.2.20`); may cause toolchain incompatibility.
2. **Medium**: Health Services dependency pinned to release candidate `1.1.0-rc02`; should use stable release.
3. **Low**: `kotlin {}` block depends on Flutter Gradle plugin implicitly applying the Kotlin plugin.

---

### CI/CD — build-ios.yml

**File:** `.github/workflows/build-ios.yml`

**Issues:**
1. **High**: Signed archive step missing `CODE_SIGN_STYLE=Manual` and `PROVISIONING_PROFILE_SPECIFIER=build`.
2. **High**: Hardcoded bundle ID in `ExportOptions.plist`.
3. **Medium**: Test destination simulator name may not match available simulators.
4. **Low**: `setup-xcode` pinned to mutable `@v1` tag.
5. **Low**: Xcode version `"16"` may select a beta.

**Items verified as correct:**
- Xcode version selection on `macos-15` runner.
- Unsigned IPA packaging for SideStore (manual Payload-directory zip).
- Artifact upload path and retention.
- Code signing logic with `env.USE_CODE_SIGNING` flag.
- Keychain lifecycle management.
- Pipefail handling for `xcodebuild | xcpretty`.

---

## Summary

| Severity | iOS App | Wear OS App | CI/CD | Total |
|----------|---------|-------------|-------|-------|
| **Critical** | 10 | 4 | 0 | 14 |
| **High** | 10 | 11 | 2 | 23 |
| **Medium** | 8 | 8 | 1 | 17 |
| **Low** | 9 | 8 | 2 | 19 |
| **Total** | 37 | 31 | 5 | 73 |

**Top priorities:**
1. Fix `AncsClient.kt` BufferOverflow (crash on first notification)
2. Add Health Services permissions to AndroidManifest
3. Add app-group entitlement to both iOS targets
4. Fix `ProtoSerialization.swift` varint overflow (crash on malicious input)
5. Fix `GattClient.swift` single reassembler (data corruption)
6. Remove unused `SwiftProtobuf` and `Zip` pods
7. Fix `BLEManager.swift` state machine (stuck in wrong state)
