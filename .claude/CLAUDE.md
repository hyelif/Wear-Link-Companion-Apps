# WearLink

**Project:** Companion apps — iPhone ⟷ Wear OS watch over BLE
**Status:** Development
**Primary Goal:** Fully functioning iOS + Wear OS companion apps

## Commands

```bash
# Wear OS app
cd wear_app && flutter pub get && flutter run -d <device>

# iOS app
cd ios_app && xcodegen generate && pod install && open WearLink.xcworkspace

# Test (Flutter)
cd wear_app && flutter test

# Test (iOS)
cd ios_app && xcodebuild test -workspace WearLink.xcworkspace -scheme WearLink -destination 'platform=iOS Simulator,name=iPhone 16'

# Proto regenerate
protoc --dart_out=wear_app/lib/gen -Iprotocol/proto protocol/proto/*.proto

# Graphify
graphify update .
graphify query "<question>"
```

## Architecture

iOS = BLE Central, Watch = BLE Peripheral (GATT server). Protobuf wire format over custom packet codec (CRC-8, chunked reassembly). Health data flows watch→iPhone→HealthKit. Call/notification/music control flows bidirectionally.

## Key Decisions

- **Mixed stack**: native Swift/SwiftUI for iOS (CoreBluetooth, HealthKit), Flutter for Wear OS (signals_dart state, Kotlin platform channels). Rationale: each platform's native APIs are irreplaceable; Flutter gives faster Wear UI iteration.
- **No SwiftProtobuf**: hand-written ProtoCodec avoids CocoaPods dependency for protobuf — Podfile is empty.
- **Foreground Service (Phase 17)**: Android FGS keeps BLE advertiser alive when watch screen dims; bonding (Phase 18) enables reconnect without re-pairing.

## Domain Knowledge

- **FE10/FE20/FE21...**: GATT characteristic UUIDs (prefix encodes feature: FE10=deviceInfo, FE20=healthStream, FE21=healthControl, FE30=callEvent, FE31=callAction, FE40=notification, FE41=notificationAction, FE50=musicNowPlaying, FE51=musicCommand, FE60=linkControl)
- **PacketCodec**: custom framing (header + payload + CRC-8 SMBUS), supports multi-frame reassembly for payloads > MTU
- **CallKit limit**: iOS CXCallObserver can't provide caller name/number to 3rd-party apps — "Unknown" on watch is a hard platform limit

## Don'ts

- Don't modify generated protobuf files (`wear_app/lib/gen/*.pb*`)
- Don't modify graphify-out/ directly — use `graphify update .`
