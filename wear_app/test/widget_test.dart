// Smoke test: app boots to the disconnected state without crashing.
// Mocks the BLE platform channels so no native plugin is needed.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wear_app/ble/gatt_client.dart';
import 'package:wear_app/platform/ble_peripheral_channel.dart';
import 'package:wear_app/platform/health_services_channel.dart';
import 'package:wear_app/main.dart' as app;
import 'package:wear_app/signals/ble_signal.dart';
import 'package:wear_app/signals/health_signal.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const mc = MethodChannel('wearlink/ble');
    messenger.setMockMethodCallHandler(mc, (call) async {
      // start/stop/advertiseStart/advertiseStop/notify -> truthy
      return true;
    });
    // Health method channel: start/stop/startActive/stopActive/requestPermissions
    // -> truthy so HealthSignal.start() doesn't hit an unhandled handler.
    const hc = MethodChannel('wearlink/health');
    messenger.setMockMethodCallHandler(hc, (call) async => true);
    // init app globals. ConnectionScreen.build reads healthSignal during the
    // first frame (Live Health Stats card), so it MUST be initialized here —
    // the test pumps WearLinkApp directly and never calls main(), where the
    // real safe-start init would have constructed it.
    app.bleSignal = BleSignal();
    app.gatt = GattClient(channel: BlePeripheralChannel());
    app.gatt.start();
    app.healthChannel = HealthServicesChannel();
    app.healthSignal = HealthSignal(app.healthChannel);
  });

  testWidgets('shows disconnected prompt', (tester) async {
    await tester.pumpWidget(const app.WearLinkApp());
    await tester.pump();
    expect(find.text('Searching for iPhone…'), findsOneWidget);
  });
}