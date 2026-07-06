# WearLink — iOS app

Native Swift / SwiftUI companion. BLE **central**. Talks to the Wear OS watch
(`../wear_app`) over the shared GATT protocol (`../protocol`).

## Prereqs
- macOS + Xcode 15+
- XcodeGen: `brew install xcodegen`
- CocoaPods: `sudo gem install cocoapods` (or `brew install cocoapods`)
- Apple developer account (HealthKit + NotificationServiceExtension need provisioning)

## Setup
```bash
cd ios_app
xcodegen generate        # creates WearLink.xcodeproj
pod install              # SwiftProtobuf + Zip
open WearLink.xcworkspace
```
Set `DEVELOPMENT_TEAM` in `project.yml` (or in Xcode Signing & Capabilities)
before building to a device.

## Structure
```
WearLink/
  App/      @main, DI container, root view
  BLE/      CBCentralManager, GattClient, PacketCodec, UUID table
  Features/
    Health/        HealthKit writer + view model
    Call/          CallKit detect + action
    Notification/   forward WearLink-app notifs to watch (3rd-party blocked — see §9)
    Music/         own-app media control (system media blocked — see §9)
  Storage/  pending-sample cache
  UI/       SwiftUI views
  Resources/ Info.plist, entitlements
NotificationServiceExtension/   intercepts WearLink-app push payloads
```

## Wire protocol
Generated Swift from `../protocol/proto/wearlink.proto`. The CI workflow runs
this; manually:
```bash
mkdir -p WearLink/Generated
protoc --swift_out=WearLink/Generated -I../protocol/proto ../protocol/proto/wearlink.proto
```
`WearLink/Generated/` is under the `WearLink` target sources path, so XcodeGen
includes it automatically after `xcodegen generate`.

## CI + SideStore
`.github/workflows/build-ios.yml` builds an `.ipa` on every push to `main` /
tag `v*` / manual dispatch. It runs unit tests, then archives + exports an
**unsigned** IPA suitable for [SideStore](https://sidestore.io) (SideStore
resigns on-device with your Apple ID).

### To test via SideStore
1. Push to `main` (or trigger the workflow).
2. Download the `WearLink-ipa` artifact from the Actions run.
3. Unzip: `unzip WearLink-ipa.zip` → `WearLink-*.ipa`.
4. In SideStore: `+` → Browse → select the `.ipa` → install. SideStore resigns
   it with your Apple ID (anisette server + login).

### Optional: developer-signed build
Set these repo secrets to produce a signed IPA instead of unsigned:
- `IOS_SIGNING_P12` — base64 of your `.p12`
- `IOS_SIGNING_P12_PASSWORD`
- `IOS_PROVISION_PROFILE` — base64 of `.mobileprovision`
- `IOS_KEYCHAIN_PASSWORD` — temp keychain password (any value)
- `IOS_TEAM_ID`

With `IOS_SIGNING_P12` present the workflow switches to the signed path.

## Known limits (honest — see ../Software-Structure.md §9)
- Call **audio** does not route to watch (watch = remote control).
- **3rd-party notification forwarding** blocked by iOS sandbox.
- **System media control** (Spotify/Apple Music) needs private API → App Store rejection; own-app only.