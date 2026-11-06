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
  testWidgets('adopts the current port and discards the old view', (
    tester,
  ) async {
    final generation = ValueNotifier<int>(0);
    addTearDown(generation.dispose);
    var port = 24801;
    final builtPorts = <int>[];
    final mountedPorts = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: SkinViewHost(
          serveGeneration: generation,
          port: () => port,
          builder: (value) {
            builtPorts.add(value);
            return _PortProbe(
              port: value,
              onMount: () => mountedPorts.add(value),
            );
          },
        ),
      ),
    );

    expect(builtPorts, [24801]);
    expect(mountedPorts, [24801]);
    expect(find.text('port:24801'), findsOneWidget);

    port = 24802;
    generation.value = 1;
    await tester.pump();

    expect(builtPorts, [24801, 24802]);
    expect(mountedPorts, [24801, 24802]);
    expect(find.text('port:24802'), findsOneWidget);
  });

  testWidgets('reports a failure raised while the view is replaced', (
    tester,
  ) async {
    final generation = ValueNotifier<int>(0);
    final failure = ValueNotifier<String?>(null);
    addTearDown(generation.dispose);
    addTearDown(failure.dispose);
    var port = 24801;

    await tester.pumpWidget(
      MaterialApp(
        home: SkinViewHost(
          serveGeneration: generation,
          port: () => port,
          failure: failure,
          onFailureShown: () => failure.value = null,
          builder: (value) => Scaffold(body: Text('port:$value')),
        ),
      ),
    );

    // A failed switch restores the previous skin, which advances the
    // generation and replaces the skin view before the failure is reported.
    port = 24803;
    generation.value = 1;
    await tester.pump();
    failure.value = 'Could not switch to broken — kept the previous skin';
    await tester.pump();

    expect(
      find.text('Could not switch to broken — kept the previous skin'),
      findsOneWidget,
    );
    expect(failure.value, isNull);
    expect(find.text('port:24803'), findsOneWidget);
  });

  testWidgets('replacing the view keeps the skin brightness, leaving resets', (
    tester,
  ) async {
    final logs = WebViewLogService(logDirectoryPath: '.');
    final settingsController = SettingsController(MockSettingsService());
    final displayController = DisplayController(
      de1Controller: MockDe1Controller(controller: DeviceController(const [])),
      settingsController: settingsController,
      setBrightness: (_) async {},
      resetBrightness: () async {},
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

    final generation = ValueNotifier<int>(0);
    addTearDown(generation.dispose);
    var port = 24801;

    await tester.pumpWidget(
      MaterialApp(
        home: SkinViewHost(
          serveGeneration: generation,
          port: () => port,
          builder: (value) => SkinView(
            settingsController: settingsController,
            webViewLogService: logs,
            deviceIp: '127.0.0.1',
            displayController: displayController,
            port: value,
            webView: const SizedBox.expand(key: Key('webview')),
          ),
        ),
      ),
    );

    await displayController.setBrightness(40);
    expect(displayController.currentState.requestedBrightness, 40);

    port = 24802;
    generation.value = 1;
    await tester.pump();

    expect(displayController.currentState.requestedBrightness, 40);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(displayController.currentState.requestedBrightness, 100);
  });
}

class _PortProbe extends StatefulWidget {
  const _PortProbe({required this.port, required this.onMount});

  final int port;
  final VoidCallback onMount;

  @override
  State<_PortProbe> createState() => _PortProbeState();
}

class _PortProbeState extends State<_PortProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => Text('port:${widget.port}');
}
