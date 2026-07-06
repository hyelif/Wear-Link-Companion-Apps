# WearLink

Companion bridge: **iPhone** ⟷ **Wear OS watch** over BLE.

Replaces the abandoned OrienLabs BLE bridge. iOS = Central, Watch = Peripheral.

## Monorepo layout

| Path | What |
|------|------|
| `wear_app/` | Wear OS app — Flutter UI + `signals` state + native Kotlin platform channels (BLE peripheral, Health Services) |
| `ios_app/` | iOS app — native Swift/SwiftUI, CocoaPods, CoreBluetooth (central) |
| `protocol/` | Shared BLE GATT contract + protobuf definitions (single source of truth for both apps) |
| `Software-Structure.md` | Architecture spec |
| `progress.md` | Status tracker / roadmap / metrics |

## Features

- Health data sync (watch → iPhone → HealthKit)
- Call handling on watch (remote control — no audio routing, platform-blocked)
- Notification forwarding (plumbing; 3rd-party cross-app forwarding blocked by iOS sandbox)
- Music control on watch (own-app audio; system media blocked via public API)

See `Software-Structure.md` §9 for the honest platform-limitations register.

## Build

### Wear OS app
```bash
cd wear_app
flutter pub get
# regenerate proto dart:
#   protoc --dart_out=lib/gen -I../protocol/proto ../protocol/proto/*.proto
flutter run -d <wear-os-emulator-or-device>
```

### iOS app
```bash
cd ios_app
# requires XcodeGen: brew install xcodegen
xcodegen generate        # produces WearLink.xcodeproj
pod install              # CocoaPods
open WearLink.xcworkspace
```

## Status

Not started — architecture defined. See `progress.md`.# wear_link
# Wear-Link-Companion-Apps
