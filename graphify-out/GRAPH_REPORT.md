# Graph Report - .  (2026-07-08)

## Corpus Check
- Corpus is ~39,772 words - fits in a single context window. You may not need a graph.

## Summary
- 922 nodes · 1541 edges · 76 communities (62 shown, 14 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 33 edges (avg confidence: 0.78)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- iOS BLE & Feature Controllers
- iOS Core & App Container
- iOS Extensions & Views
- Dart BLE & Platform (Watch)
- Android Kotlin (Watch BLE)
- Android Health & ANCS
- Android BLE Service
- Dart Signals & Data Flow
- Dart UI Components
- Dart Main & App Shell
- Dart Music Control
- Dart Health Signal
- iOS Call Controller
- iOS Notification Forwarder
- Dart Platform Channels
- iOS Music Controller
- Dart Notification Signal
- Dart Call Signal
- Dart Health Services
- Dart BLE Codec
- iOS Views & Navigation
- iOS Device Details
- Dart ANCS Channel
- Protocol & Documentation
- Dart Widgets & Theme
- iOS Health Manager
- iOS Settings & Models
- iOS BLE GATT Client
- iOS Protobuf Codec
- iOS UI Components
- Tests & Integration
- CI/CD Build Pipeline
- Dart BLE Peripheral
- Project Root & Config
- iOS Packet Codec
- iOS Health View
- iOS Call View
- iOS Notification View
- iOS Music View
- iOS Connection View
- iOS App Entry & DI
- Dart codec & CRC
- iOS Storage & Cache
- Dart pubspec deps
- iOS Proto Models
- iOS Call Actions
- iOS Music Commands
- iOS Notif Actions
- iOS Health Frame
- Android Health Collect
- Android Health Permissions
- iOS Device Info
- iOS Unit Tests
- iOS Wearable Model
- Android ANCS Client
- iOS Packet Codec Test
- iOS Protocol Docs
- Wear App Config
- Community 58
- Community 61
- Community 63
- Community 64
- Community 65
- Community 66
- Community 67
- Community 68
- Community 69
- Community 70
- Community 72
- Community 75

## God Nodes (most connected - your core abstractions)
1. `ProtoCodec` - 47 edges
2. `CallScreen (Wear UI)` - 40 edges
3. `MusicScreen (Wear UI)` - 39 edges
4. `MusicSignal (signals_dart)` - 31 edges
5. `NotificationSignal (signals_dart)` - 29 edges
6. `BLEManager` - 28 edges
7. `MusicController` - 26 edges
8. `HealthSignal (signals_dart)` - 25 edges
9. `NotificationScreen (Wear UI)` - 23 edges
10. `NotificationForwarder` - 22 edges

## Surprising Connections (you probably didn't know these)
- `NotificationForwarder` --requires--> `App Group Entitlement (group.com.wearlink.notification)`  [EXTRACTED]
  ios_app/WearLink/Features/Notification/NotificationForwarder.swift → Optimization.md
- `Notification Forwarding Flow` --uses--> `NotificationForwarder`  [EXTRACTED]
  Software-Structure.md → ios_app/WearLink/Features/Notification/NotificationForwarder.swift
- `Call Handling on Watch Flow` --uses--> `CallSignal (signals_dart)`  [EXTRACTED]
  Software-Structure.md → wear_app/lib/signals/call_signal.dart
- `Music Control on Watch Flow` --uses--> `MusicSignal (signals_dart)`  [EXTRACTED]
  Software-Structure.md → wear_app/lib/signals/music_signal.dart
- `Notification Forwarding Flow` --uses--> `NotificationSignal (signals_dart)`  [EXTRACTED]
  Software-Structure.md → wear_app/lib/signals/notification_signal.dart

## Import Cycles
- None detected.

## Communities (76 total, 14 thin omitted)

### Community 0 - "iOS BLE & Feature Controllers"
Cohesion: 0.05
Nodes (34): AVFoundation, CBCharacteristic, CBCharacteristicWriteType, CBPeripheralDelegate, CBService, CBUUID, CoreBluetooth, Foundation (+26 more)

### Community 1 - "iOS Core & App Container"
Cohesion: 0.16
Nodes (11): ProtoCodec, Bool, Data, Double, Float, Int, String, UInt32 (+3 more)

### Community 2 - "iOS Extensions & Views"
Cohesion: 0.08
Nodes (23): App Group Entitlement (group.com.wearlink.notification), CI/CD Build Workflow, CocoaPods Dependency Manager, NotificationService, Void, XcodeGen Project Configuration, ForwardedNotificationItem, NotificationBridge (+15 more)

### Community 3 - "Dart BLE & Platform (Watch)"
Cohesion: 0.07
Nodes (37): StatelessWidget, _ActionButton, _ActiveView, CallScreen, _IdleView, _IncomingView, _OutgoingView, MusicScreen (Wear UI) (+29 more)

### Community 4 - "Android Kotlin (Watch BLE)"
Cohesion: 0.08
Nodes (19): BluetoothGatt, BluetoothGattCharacteristic, Long, AncsClient, AncsNotification, BluetoothAdapter, BluetoothDevice, ByteArray (+11 more)

### Community 5 - "Android Health & ANCS"
Cohesion: 0.09
Nodes (19): android, Boolean, UUID, BlePeripheralService, ConnState, BluetoothAdapter, BluetoothDevice, ByteArray (+11 more)

### Community 6 - "Android BLE Service"
Cohesion: 0.08
Nodes (18): FlutterActivity, Instant, MeasureClient, PassiveMonitoringClient, HealthCollector, List, Unit, Sample (+10 more)

### Community 7 - "Dart Signals & Data Flow"
Cohesion: 0.09
Nodes (25): dart:async, static const, Stream, StreamController, StreamSubscription, AncsChannel, _controller, dispose (+17 more)

### Community 8 - "Dart UI Components"
Cohesion: 0.08
Nodes (26): StatefulWidget, Stopwatch, CallScreen (Wear UI), build, caller, callSignal, _CallTimer, _CallTimerState (+18 more)

### Community 9 - "Dart Main & App Shell"
Cohesion: 0.08
Nodes (23): MaterialPageRoute, package:wear_app/features/call/call_screen.dart, package:wear_app/features/health/health_screen.dart, package:wear_app/features/music/music_screen.dart, package:wear_app/features/notification/notification_screen.dart, package:wear_app/platform/ancs_channel.dart, package:wear_app/platform/health_services_channel.dart, package:wear_app/signals/call_signal.dart (+15 more)

### Community 10 - "Dart Music Control"
Cohesion: 0.08
Nodes (24): MusicSignal (signals_dart), album, artBytes, artist, copyWith, dispose, durationMs, _gatt (+16 more)

### Community 11 - "Dart Health Signal"
Cohesion: 0.09
Nodes (22): callAction, callEvent, channel, deviceInfo, GattClient, GattUuid, healthControl, healthStream (+14 more)

### Community 12 - "iOS Call Controller"
Cohesion: 0.14
Nodes (11): AnyObject, MusicController, Any, Bool, Data, Date, Float, String (+3 more)

### Community 13 - "iOS Notification Forwarder"
Cohesion: 0.16
Nodes (21): Int64, Action, accept, actionUnspecified, dismiss, end, mute, reject (+13 more)

### Community 14 - "Dart Platform Channels"
Cohesion: 0.10
Nodes (20): static const EventChannel, static const MethodChannel, advertiseStart, advertiseStop, BleFrameEvent, BlePeripheralChannel, connState, data (+12 more)

### Community 15 - "iOS Music Controller"
Cohesion: 0.12
Nodes (18): Codable, CodingKey, Decoder, Identifiable, CodingKeys, analytics, autoConnect, bidirectionalSync (+10 more)

### Community 16 - "Dart Notification Signal"
Cohesion: 0.10
Nodes (19): Map, static const int, Uint8List?, add, _buf, clear, continuation, crc8 (+11 more)

### Community 17 - "Dart Call Signal"
Cohesion: 0.11
Nodes (20): package:wear_app/signals/notification_signal.dart, ValueChanged, VoidCallback, NotificationScreen (Wear UI), _appColor, build, _buildEmpty, _buildList (+12 more)

### Community 18 - "Dart Health Services"
Cohesion: 0.11
Nodes (19): package:fixnum/fixnum.dart, ../platform/health_services_channel.dart, HealthSignal (signals_dart), _buffer, calories, _channel, dispose, distance (+11 more)

### Community 19 - "Dart BLE Codec"
Cohesion: 0.11
Nodes (19): NotificationSignal (signals_dart), appName, body, copyWith, dismiss, dispose, fromProto, gatt (+11 more)

### Community 20 - "iOS Views & Navigation"
Cohesion: 0.16
Nodes (10): CBCentralManager, CBCentralManagerDelegate, BLEManager, Any, CBPeripheral, GattClient, String, TimeInterval (+2 more)

### Community 21 - "iOS Device Details"
Cohesion: 0.15
Nodes (11): RootView, CallView, ConnectionView, SectionHeader, String, DeviceDetailsView, Bool, DeviceInfoSection (+3 more)

### Community 22 - "Dart ANCS Channel"
Cohesion: 0.12
Nodes (16): package:wear_app/gen/wearlink.pb.dart, CallSignal (signals_dart), callActive, caller, callerName, callId, CallInfo, CallSignal (+8 more)

### Community 23 - "Protocol & Documentation"
Cohesion: 0.20
Nodes (15): Battery Optimization Strategy, BlePeripheralService (Kotlin), Bonding via LE Secure Connections, CallAction Characteristic (0xFE31), CallController (CallKit), Call Handling on Watch Flow, CallKit, MusicCommand Characteristic (0xFE51) (+7 more)

### Community 24 - "Dart Widgets & Theme"
Cohesion: 0.13
Nodes (15): IconData, package:flutter/material.dart, package:signals/signals_flutter.dart, package:wear_app/signals/health_signal.dart, HealthScreen (Wear UI), build, health, HealthScreen (+7 more)

### Community 25 - "iOS Health Manager"
Cohesion: 0.15
Nodes (13): Command, cmdUnspecified, next, pause, play, previous, seek, sendNow (+5 more)

### Community 26 - "iOS Settings & Models"
Cohesion: 0.23
Nodes (12): Ack model (LinkControl seq echo, 3x retry with backoff), BLEManager (CBCentralManager), CallEvent Characteristic (0xFE30), CoreBluetooth Framework, DeviceCardView (SwiftUI), DevicesListView (SwiftUI), Duty-cycled BLE scanning (2s on / 8s off), HealthControl Characteristic (0xFE21) (+4 more)

### Community 27 - "iOS BLE GATT Client"
Cohesion: 0.18
Nodes (11): CaseIterable, BackgroundColor, black, blue, green, random, red, white (+3 more)

### Community 28 - "iOS Protobuf Codec"
Cohesion: 0.24
Nodes (6): HealthManager, Bool, Date, Double, Int, UInt32

### Community 29 - "iOS UI Components"
Cohesion: 0.24
Nodes (7): CXCall, CXCallObserver, CXCallObserverDelegate, CXProvider, CXProviderDelegate, CallController, String

### Community 30 - "Tests & Integration"
Cohesion: 0.20
Nodes (9): package:flutter/services.dart, package:flutter_test/flutter_test.dart, package:integration_test/integration_test.dart, package:wear_app/ble/gatt_client.dart, package:wear_app/main.dart, package:wear_app/platform/ble_peripheral_channel.dart, package:wear_app/signals/ble_signal.dart, main (+1 more)

### Community 31 - "CI/CD Build Pipeline"
Cohesion: 0.27
Nodes (10): Apple Notification Center Service (ANCS), AncsClient (Kotlin), AncsPlugin (FlutterPlugin), HealthCollector (Kotlin), Wear OS Health Services API, HealthServicesPlugin (FlutterPlugin), MainActivity (Wear OS), Notification Forwarding Flow (+2 more)

### Community 32 - "Dart BLE Peripheral"
Cohesion: 0.20
Nodes (10): MapSignal, package:signals/signals.dart, Signal, BleSignal (signals_dart), BleSignal, connection, ConnState, lastFrame (+2 more)

### Community 33 - "Project Root & Config"
Cohesion: 0.22
Nodes (9): AppContainer (DI Container), Health Data Sync Flow, HealthStore (local cache + dedupe), HealthStream Characteristic (0xFE20), HealthViewModel (HealthKit), HealthKit Framework, MPNowPlayingInfoCenter, MPRemoteCommandCenter (+1 more)

### Community 34 - "iOS Packet Codec"
Cohesion: 0.22
Nodes (9): Equatable, State, connected, connecting, disconnected, poweredOff, scanning, Bool (+1 more)

### Community 35 - "iOS Health View"
Cohesion: 0.22
Nodes (9): `Type`, calories, distanceMeters, heartRateBpm, hrvMs, sleep, spo2Percent, steps (+1 more)

### Community 36 - "iOS Call View"
Cohesion: 0.28
Nodes (6): HealthView, MetricCard, Color, Date, Double, String

### Community 37 - "iOS Notification View"
Cohesion: 0.25
Nodes (7): Destination, DevicesListView, FeatureCard, Bool, Color, Int, String

### Community 38 - "iOS Music View"
Cohesion: 0.25
Nodes (8): Kind, ack, heartbeat, kindUnspecified, nack, reconnectToken, LinkControl, Data

### Community 39 - "iOS Connection View"
Cohesion: 0.29
Nodes (4): App, AppContainer, WearLinkApp, Scene

### Community 40 - "iOS App Entry & DI"
Cohesion: 0.29
Nodes (7): BLE GATT Protocol, BluetoothGattServer, DeviceInfo Characteristic (0xFE10), Flutter Platform (Wear OS UI), Watch BLE Peripheral Role, WearableDevice (Model), WearLink Project

### Community 41 - "Dart codec & CRC"
Cohesion: 0.29
Nodes (7): Chunking Mechanism (continuation flag), CRC-8/SMBUS (poly 0x07), Frame Layout (seq:u16, flags:u8, len:u16, payload, crc8), GattClient (CBPeripheralDelegate), PacketCodec (iOS Swift), ProtoSerialization, PacketCodec (Dart)

### Community 42 - "iOS Storage & Cache"
Cohesion: 0.47
Nodes (4): AVAudioSession, CXAnswerCallAction, CXEndCallAction, CXSetMutedCallAction

### Community 43 - "Dart pubspec deps"
Cohesion: 0.33
Nodes (6): 73 Issues Found in Code Audit, Optimization & Verification Report, Phase 9 - Connection Fixes (CRITICAL), Progress Tracker, UUID Mismatch Between Platforms, GattClient (Dart)

### Community 44 - "iOS Proto Models"
Cohesion: 0.40
Nodes (4): Image, Bool, String, ToggleRow

### Community 45 - "iOS Call Actions"
Cohesion: 0.50
Nodes (4): MusicCommand, MusicNowPlaying, Double, Float

### Community 46 - "iOS Music Commands"
Cohesion: 0.40
Nodes (3): MusicView, Double, String

### Community 47 - "iOS Notif Actions"
Cohesion: 0.40
Nodes (3): NotificationView, String, UInt64

### Community 48 - "iOS Health Frame"
Cohesion: 0.40
Nodes (4): DeviceCardView, Bool, Int, String

### Community 49 - "Android Health Collect"
Cohesion: 0.60
Nodes (3): Keep, GeneratedPluginRegistrant, FlutterEngine

### Community 50 - "Android Health Permissions"
Cohesion: 0.60
Nodes (3): gradlew script, die(), warn()

### Community 51 - "iOS Device Info"
Cohesion: 0.50
Nodes (3): CGFloat, DeviceIconView, String

### Community 52 - "iOS Unit Tests"
Cohesion: 0.50
Nodes (3): dart:typed_data, package:wear_app/ble/packet_codec.dart, main

### Community 53 - "iOS Wearable Model"
Cohesion: 0.50
Nodes (4): DeviceDetailsView (SwiftUI), DeviceIconView (SwiftUI), DeviceSettings (Model), ToggleRow (SwiftUI component)

### Community 56 - "iOS Protocol Docs"
Cohesion: 0.67
Nodes (3): Protobuf Definitions, Codec Framing Document, GATT Protocol Document

### Community 57 - "Wear App Config"
Cohesion: 0.67
Nodes (3): Protocol Buffers (wire format), signals_dart (reactive state), Flutter pubspec.yaml

## Knowledge Gaps
- **308 isolated node(s):** `poweredOff`, `scanning`, `connecting`, `connected`, `disconnected` (+303 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **14 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `NotificationForwarder` connect `iOS Extensions & Views` to `iOS BLE & Feature Controllers`, `Project Root & Config`, `iOS Connection View`, `iOS Views & Navigation`, `CI/CD Build Pipeline`?**
  _High betweenness centrality (0.229) - this node is a cross-community bridge._
- **Why does `NotificationSignal (signals_dart)` connect `Dart BLE Codec` to `Dart BLE Peripheral`, `Dart Signals & Data Flow`, `Dart Call Signal`, `iOS Unit Tests`, `Dart ANCS Channel`, `Wear App Config`, `Tests & Integration`, `CI/CD Build Pipeline`?**
  _High betweenness centrality (0.221) - this node is a cross-community bridge._
- **Why does `Notification Forwarding Flow` connect `CI/CD Build Pipeline` to `Dart BLE Codec`, `iOS Settings & Models`, `iOS Extensions & Views`, `Protocol & Documentation`?**
  _High betweenness centrality (0.213) - this node is a cross-community bridge._
- **What connects `poweredOff`, `scanning`, `connecting` to the rest of the system?**
  _308 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `iOS BLE & Feature Controllers` be split into smaller, more focused modules?**
  _Cohesion score 0.05499735589635114 - nodes in this community are weakly interconnected._
- **Should `iOS Extensions & Views` be split into smaller, more focused modules?**
  _Cohesion score 0.08408408408408409 - nodes in this community are weakly interconnected._
- **Should `Dart BLE & Platform (Watch)` be split into smaller, more focused modules?**
  _Cohesion score 0.06906906906906907 - nodes in this community are weakly interconnected._