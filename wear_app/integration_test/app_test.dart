// Integration smoke test. Boots the WearLink app on a real Wear OS device /
// emulator and asserts the connection screen renders. Requires a target
// device — does NOT run under plain `flutter test`.
//
// Run on a Wear OS emulator/device:
//   flutter test integration_test/app_test.dart -d <wear-os-device>
// or legacy:
//   flutter drive --driver=test_driver/integration_test.dart \
//                --target=integration_test/app_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:wear_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('WearLink end-to-end', () {
    testWidgets('boots to connection screen', (tester) async {
      app.main(); // inits bleSignal + gatt + real platform channels
      await tester.pumpAndSettle();
      // Disconnected is the initial state (no iPhone connected yet).
      expect(find.text('Searching for iPhone…'), findsOneWidget);
    });
  });
}