import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reaprime/main.dart' as app;
import 'package:reaprime/src/app.dart' show NavigationService;
import 'package:reaprime/src/services/telemetry/frame_profiler.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';

const _advanceLabels = [
  'Get Started',
  'Skip for now',
  'Continue offline',
  'Continue to Dashboard',
  'Continue',
  'Try Demo Mode',
];

const _runFor = Duration(
  seconds: int.fromEnvironment('perfDriveSeconds', defaultValue: 60),
);

Future<Object?> _get(String path) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:8080$path'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body);
  } catch (e) {
    debugPrint('PERF_DRIVE get $path failed: $e');
    return null;
  } finally {
    client.close();
  }
}

Future<bool> _machineConnected() async {
  final devices = await _get('/api/v1/devices');
  if (devices is! List) return false;
  return devices.any(
    (device) =>
        device is Map &&
        device['type'] == 'machine' &&
        device['state'] == 'connected',
  );
}

const _perfSkin = String.fromEnvironment('perfSkin');

final _appArgs = <String>[
  '--force-onboarding',
  '--no-account',
  if (_perfSkin.isNotEmpty) ...['--skin', _perfSkin],
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  app.main(_appArgs);

  testWidgets('drives the onboarding flow for frame capture', (tester) async {
    final deadline = DateTime.now().add(_runFor);
    var taps = 0;
    var connected = false;
    var lastConnectCheck = DateTime.fromMillisecondsSinceEpoch(0);

    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));

      String? next;
      for (final label in _advanceLabels) {
        if (find.text(label).evaluate().isNotEmpty) {
          next = label;
          break;
        }
      }
      if (next == null) continue;

      if (next == 'Continue to Dashboard') {
        final now = DateTime.now();
        if (now.difference(lastConnectCheck).inSeconds >= 2) {
          connected = await _machineConnected();
          lastConnectCheck = now;
        }
        if (!connected) continue;
      }

      await tester.tap(find.text(next).first, warnIfMissed: false);
      taps++;
      debugPrint('PERF_DRIVE tap $taps: $next');
      await tester.pump(const Duration(milliseconds: 1500));
    }

    debugPrint('PERF_DRIVE taps=$taps');

    var skinReached = find.byType(SkinView).evaluate().isNotEmpty;
    var skinForced = false;
    if (!skinReached) {
      final navigator = NavigationService.navigatorKey.currentState;
      if (navigator == null) {
        debugPrint('PERF_DRIVE skin not reached; navigator is null');
      } else {
        debugPrint('PERF_DRIVE skin not reached; forcing SkinView.open');
        skinForced = true;
        await SkinView.open(navigator);
        final skinDeadline = DateTime.now().add(const Duration(seconds: 25));
        while (DateTime.now().isBefore(skinDeadline)) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find.byType(SkinView).evaluate().isNotEmpty) break;
        }
        skinReached = find.byType(SkinView).evaluate().isNotEmpty;
      }
    }
    debugPrint('PERF_DRIVE skin reached=$skinReached forced=$skinForced');
    final devices = await _get('/api/v1/devices');
    final settings = await _get('/api/v1/settings');
    debugPrint('PERF_DRIVE devices=$devices');

    final report = FrameProfiler.snapshot();
    if (report != null) {
      binding.reportData = {
        'perf_report': report,
        'devices': devices,
        'settings': settings,
        'taps': taps,
        'skin_reached': skinReached,
        'skin_forced': skinForced,
      };
    }
    expect(taps, greaterThan(0), reason: 'no onboarding advance control found');
  });
}
