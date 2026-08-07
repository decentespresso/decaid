import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart' show UpdateChannel;
import 'package:reaprime/src/services/macos_updater.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('net.tadel.reaprime/macos_updater');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('is a no-op off macOS', () async {
    final updater = MacOSUpdater(supported: false);

    await updater.configure(
      automaticChecks: true,
      channel: UpdateChannel.stable,
    );
    await updater.setAutomaticChecks(false);
    await updater.setChannel(UpdateChannel.beta);
    await updater.checkForUpdates();

    expect(calls, isEmpty);
    expect(updater.isAvailable, isFalse);
  });

  test('starts unavailable until configure succeeds', () async {
    final updater = MacOSUpdater(supported: true);
    expect(updater.isAvailable, isFalse);

    await updater.setAutomaticChecks(false);
    await updater.setChannel(UpdateChannel.beta);
    await updater.checkForUpdates();

    expect(calls, isEmpty);
  });

  test(
    'configure sends automaticChecks and channel and marks available',
    () async {
      final updater = MacOSUpdater(supported: true);

      await updater.configure(
        automaticChecks: true,
        channel: UpdateChannel.beta,
      );

      expect(updater.isAvailable, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'configure');
      expect(calls.single.arguments, {
        'automaticChecks': true,
        'channel': 'beta',
      });
    },
  );

  test('a failed configure stays unavailable and rethrows', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'configure') {
            throw PlatformException(code: 'configure_failed');
          }
          calls.add(call);
          return null;
        });
    final updater = MacOSUpdater(supported: true);

    await expectLater(
      updater.configure(automaticChecks: true, channel: UpdateChannel.stable),
      throwsA(isA<PlatformException>()),
    );
    expect(updater.isAvailable, isFalse);

    await updater.setAutomaticChecks(false);
    await updater.checkForUpdates();
    expect(calls, isEmpty);
  });

  test('setAutomaticChecks sends the enabled flag', () async {
    final updater = MacOSUpdater(supported: true);
    await updater.configure(
      automaticChecks: true,
      channel: UpdateChannel.stable,
    );
    calls.clear();

    await updater.setAutomaticChecks(false);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setAutomaticChecks');
    expect(calls.single.arguments, {'enabled': false});
  });

  test('setChannel sends the channel name', () async {
    final updater = MacOSUpdater(supported: true);
    await updater.configure(
      automaticChecks: true,
      channel: UpdateChannel.stable,
    );
    calls.clear();

    await updater.setChannel(UpdateChannel.stable);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setChannel');
    expect(calls.single.arguments, {'channel': 'stable'});
  });

  test('checkForUpdates sends no arguments', () async {
    final updater = MacOSUpdater(supported: true);
    await updater.configure(
      automaticChecks: true,
      channel: UpdateChannel.stable,
    );
    calls.clear();

    await updater.checkForUpdates();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'checkForUpdates');
    expect(calls.single.arguments, isNull);
  });

  test('defaults isSupported to the host platform', () {
    final updater = MacOSUpdater();
    expect(updater.isSupported, Platform.isMacOS);
  });
}
