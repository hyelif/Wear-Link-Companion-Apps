# WearLink

**iPhone** ⟷ **Wear OS watch** — companion bridge over BLE.

Replaces the abandoned OrienLabs BLE bridge. iOS acts as BLE Central, Watch as BLE Peripheral (GATT server).

## Features

| Feature | Direction | Status |
|---------|-----------|--------|
| Health data sync (HR, steps → HealthKit) | Watch → iPhone | ✅ |
| Call handling on watch (remote control) | Bidirectional | ✅ |
| Notification forwarding | iPhone → Watch | ✅ |
| Music control on watch | Bidirectional | ✅ |

> See [platform limitations](#platform-limitations) for honest capability boundaries.

## Monorepo layout

| Path | What |
|------|------|
| `wear_app/` | Wear OS app — Flutter UI + `signals` state + Kotlin platform channels (BLE peripheral, Health Services) |
| `ios_app/` | iOS app — native Swift/SwiftUI, CoreBluetooth (central), HealthKit |
| `protocol/` | Shared BLE GATT contract + protobuf definitions — single source of truth for both apps |

## Prerequisites

- **Wear OS**: Flutter SDK (≥3.22), Android device/emulator with Wear OS
- **iOS**: macOS, Xcode 16+, XcodeGen, CocoaPods
- **Proto**: protoc + dart plugin (for regenerating wire types)

## Build & run

### Wear OS app

```bash
cd wear_app
flutter pub get
flutter run -d <wear-os-emulator-or-device>
```

Regenerate protobuf Dart code after changing `protocol/`:

```bash
protoc --dart_out=lib/gen -I../protocol/proto ../protocol/proto/*.proto
```

### iOS app

```bash
cd ios_app
brew install xcodegen          # if not installed
xcodegen generate               # produces WearLink.xcodeproj
pod install                     # CocoaPods
open WearLink.xcworkspace
```

### Run tests

```bash
# Flutter
cd wear_app && flutter test

# iOS
cd ios_app && xcodebuild test \
  -workspace WearLink.xcworkspace \
  -scheme WearLink \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  | xcpretty
```

## Architecture

```
┌──────────────┐       BLE GATT        ┌──────────────────┐
│   iPhone      │ ◄──────────────────► │   Wear OS Watch   │
│  (Central)    │   (peripheral)       │  (Peripheral)     │
│               │                      │                   │
│ CoreBluetooth │                      │ Flutter UI        │
│ HealthKit     │                      │ signals_dart      │
│ SwiftUI       │                      │ Kotlin channels   │
└──────────────┘                      └──────────────────┘
```

Wire format: protobuf over custom packet codec (CRC-8 SMBUS, multi-frame reassembly for payloads > MTU).

## Platform limitations

These are hard platform limits, not bugs:

- **Caller ID**: iOS CXCallObserver can't provide caller name/number to 3rd-party apps — watch always shows "Unknown"
- **Notification content**: iOS sandbox blocks 3rd-party apps from reading other apps' notifications; forwarding works for own-app notifications only
- **System media**: iOS MediaPlayer API doesn't expose system media playback to 3rd-party apps; music control works for own-app audio only

## Status

Active development. See `progress.md` for roadmap and metrics.

## License

MIT
