import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';

import '../../helpers/mock_settings_service.dart';

void main() {
  testWidgets('removing the skin view restores OS-managed brightness', (
    tester,
  ) async {
    var restoreCalls = 0;
    final logs = WebViewLogService(logDirectoryPath: '.');

    await tester.pumpWidget(
      MaterialApp(
        home: SkinView(
          settingsController: SettingsController(MockSettingsService()),
          webViewLogService: logs,
          deviceIp: '127.0.0.1',
          restoreBrightness: () async {
            restoreCalls++;
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());

    expect(restoreCalls, 1);
    logs.dispose();
  });
}
