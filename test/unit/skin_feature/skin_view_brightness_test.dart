import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';

import '../../helpers/mock_de1_controller.dart';
import '../../helpers/mock_settings_service.dart';

void main() {
  testWidgets(
    'native UI overrides other brightness requests when skin closes',
    (tester) async {
      final logs = WebViewLogService(logDirectoryPath: '.');
      final de1Controller = MockDe1Controller(
        controller: DeviceController(const []),
      );
      final settingsController = SettingsController(MockSettingsService());
      var resetCalls = 0;
      final displayController = DisplayController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        setBrightness: (_) async {},
        resetBrightness: () async {
          resetCalls++;
        },
        enableWakeLock: () async {},
        disableWakeLock: () async {},
        platformSupport: const DisplayPlatformSupport(
          brightness: true,
          wakeLock: false,
        ),
      );
      addTearDown(() {
        displayController.dispose();
        logs.dispose();
      });

      await displayController.setBrightness(40);
      expect(displayController.currentState.requestedBrightness, 40);

      await tester.pumpWidget(
        MaterialApp(
          home: SkinView(
            settingsController: settingsController,
            webViewLogService: logs,
            deviceIp: '127.0.0.1',
            displayController: displayController,
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(displayController.currentState.requestedBrightness, 100);
      expect(resetCalls, 1);
    },
  );
}
