import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/storage/process_session_identity.dart';

const MethodChannel _channel = MethodChannel(processSessionIdentityChannelName);

const String _probePrefix = 'kernel=';
const String _noKernelIdentity = 'none';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void registerNative(String? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => handler(call));
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null),
    );
  }

  group('process-level identity', () {
    test(
      'uses the boot id, pid and process start ticks when readable',
      () async {
        final identity = await ProcessSessionIdentityResolver(
          probe: _FakeProbe(),
          channel: _FakeChannel(),
        ).resolve();

        expect(identity, 'proc:boot-a:42:1234');
      },
    );

    test('stays isolate-independent without a readable boot id', () async {
      final first = await ProcessSessionIdentityResolver(
        probe: _FakeProbe(bootId: null),
        channel: _FakeChannel(),
      ).resolve();
      final second = await ProcessSessionIdentityResolver(
        probe: _FakeProbe(bootId: null),
        channel: _FakeChannel(),
      ).resolve();

      expect(first, 'proc:-:42:1234');
      expect(second, first);
    });

    test('never derives the identity from an isolate-local clock', () async {
      final first = await ProcessSessionIdentityResolver(
        probe: _FakeProbe(),
        channel: _FakeChannel(response: 'darwin:1:2'),
      ).resolve();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = await ProcessSessionIdentityResolver(
        probe: _FakeProbe(),
        channel: _FakeChannel(response: 'darwin:9:9'),
      ).resolve();

      expect(first, 'proc:boot-a:42:1234');
      expect(second, first);
    });

    test('derives its kernel identity from the shared probe source', () async {
      final probe = _FakeProbe();

      expect(
        await ProcessSessionIdentityResolver(
          probe: probe,
          channel: _FakeChannel(),
        ).resolve(),
        kernelProcessSessionIdentity(probe),
      );
    });

    test('changes when the process facts change', () async {
      final baseline = await ProcessSessionIdentityResolver(
        probe: _FakeProbe(),
        channel: _FakeChannel(),
      ).resolve();

      expect(
        await ProcessSessionIdentityResolver(
          probe: _FakeProbe(ticks: '4321'),
          channel: _FakeChannel(),
        ).resolve(),
        isNot(baseline),
      );
      expect(
        await ProcessSessionIdentityResolver(
          probe: _FakeProbe(pidValue: 43),
          channel: _FakeChannel(),
        ).resolve(),
        isNot(baseline),
      );
      expect(
        await ProcessSessionIdentityResolver(
          probe: _FakeProbe(bootId: 'boot-b'),
          channel: _FakeChannel(),
        ).resolve(),
        isNot(baseline),
      );
    });
  });

  group('native identity channel', () {
    test('is used when no process start ticks are readable', () async {
      final identity = await ProcessSessionIdentityResolver(
        probe: _FakeProbe(ticks: null),
        channel: _FakeChannel(response: 'darwin:4711:1700000000.42'),
      ).resolve();

      expect(identity, 'native:darwin:4711:1700000000.42');
    });

    test('resolves the same value for every engine in one process', () async {
      final first = await ProcessSessionIdentityResolver(
        probe: _FakeProbe(ticks: null),
        channel: _FakeChannel(response: 'darwin:4711:1700000000.42'),
      ).resolve();
      final second = await ProcessSessionIdentityResolver(
        probe: _FakeProbe(ticks: null),
        channel: _FakeChannel(response: 'darwin:4711:1700000000.42'),
      ).resolve();

      expect(first, isNotNull);
      expect(second, first);
    });

    test('is resolved once per resolver', () async {
      final channel = _FakeChannel(response: 'darwin:4711:1.0');
      final resolver = ProcessSessionIdentityResolver(
        probe: _FakeProbe(ticks: null),
        channel: channel,
      );

      final first = await resolver.resolve();
      final second = await resolver.resolve();

      expect(first, second);
      expect(channel.calls, 1);
    });

    test(
      'a missing native handler fails closed instead of inventing one',
      () async {
        registerNative(
          (call) =>
              throw MissingPluginException('no handler for ${call.method}'),
        );

        final identity = await ProcessSessionIdentityResolver(
          probe: _FakeProbe(ticks: null),
        ).resolve();

        expect(identity, isNull);
      },
    );

    test('a failing native handler fails closed', () async {
      registerNative((call) => throw PlatformException(code: 'FAILED'));

      expect(
        await ProcessSessionIdentityResolver(probe: _FakeProbe(ticks: null))
            .resolve(),
        isNull,
      );
    });

    test('an empty or missing native answer fails closed', () async {
      registerNative((call) => null);

      expect(
        await ProcessSessionIdentityResolver(probe: _FakeProbe(ticks: null))
            .resolve(),
        isNull,
      );

      registerNative((call) => '   ');

      expect(
        await ProcessSessionIdentityResolver(probe: _FakeProbe(ticks: null))
            .resolve(),
        isNull,
      );
    });

    test('a registered native handler supplies the identity', () async {
      registerNative(
        (call) => call.method == processSessionIdentityMethod
            ? 'darwin:4711:1700000000.42'
            : null,
      );

      expect(
        await ProcessSessionIdentityResolver(probe: _FakeProbe(ticks: null))
            .resolve(),
        'native:darwin:4711:1700000000.42',
      );
    });
  });

  group('host identity', () {
    test('parses the start time field of /proc stat', () {
      const stat =
          '1234 (Web Content (x)) R 1 1234 1234 0 -1 4194560 100 0 0 0 5 6 0 '
          '0 20 0 4 0 987654 12345 678 18446744073709551615 0 0 0 0 0 0 0 0 0 0 '
          '0 0 17 3 0 0 0 0 0';

      expect(processStartTicksFromStat(stat), '987654');
    });

    test('rejects stat lines without a numeric start time', () {
      expect(processStartTicksFromStat('1234 no-command-field 987654'), isNull);
      expect(processStartTicksFromStat('1234 (cmd) R 1 2'), isNull);
      expect(
        processStartTicksFromStat(
          '1234 (cmd) R 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18',
        ),
        isNull,
      );
      expect(
        processStartTicksFromStat(
          '1234 (cmd) R 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 abc 19',
        ),
        isNull,
      );
    });

    test('reports the host process facts it can actually read', () async {
      final identity = await resolveProcessSessionId();
      final ticks = const OsProcessSessionProbe().readProcessStartTicks();

      if (ticks == null) {
        expect(identity, isNull);
        return;
      }
      expect(identity, isNotNull);
      expect(identity, startsWith('proc:'));
      expect(await resolveProcessSessionId(), identity);
      expect(await ProcessSessionIdentityResolver().resolve(), identity);
    });

    test(
      'differs across actual process launches',
      () async {
        final executable = _dartExecutable();
        if (executable == null) {
          fail('no dart executable available for the process-launch check');
        }
        final script = File(
          '${Directory.current.path}/'
          'test/unit/services/storage/process_identity_probe.dart',
        );
        expect(script.existsSync(), isTrue, reason: script.path);
        final hostIdentity = kernelProcessSessionIdentity(
          const OsProcessSessionProbe(),
        );

        String launch() {
          final result = Process.runSync(executable, <String>[
            script.path,
          ], workingDirectory: Directory.current.path);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          final output = (result.stdout as String).trim();
          expect(output, startsWith(_probePrefix), reason: output);
          return output.substring(_probePrefix.length);
        }

        final first = launch();
        final second = launch();

        if (hostIdentity == null) {
          expect(first, _noKernelIdentity);
          expect(second, _noKernelIdentity);
          return;
        }
        expect(hostIdentity, startsWith('proc:'));
        expect(first, isNotEmpty);
        expect(second, isNotEmpty);
        expect(first, isNot(hostIdentity));
        expect(second, isNot(hostIdentity));
        expect(second, isNot(first));
      },
      skip: _dartExecutable() == null
          ? 'requires a dart executable on PATH or in the Flutter SDK'
          : null,
    );
  });
}

class _FakeProbe implements ProcessSessionProbe {
  _FakeProbe({this.bootId = 'boot-a', this.ticks = '1234', this.pidValue = 42});

  final String? bootId;
  final String? ticks;
  final int pidValue;

  @override
  String? readBootId() => bootId;

  @override
  String? readProcessStartTicks() => ticks;

  @override
  int get processId => pidValue;
}

class _FakeChannel implements ProcessSessionIdentityChannel {
  _FakeChannel({this.response});

  final String? response;
  int calls = 0;

  @override
  Future<String?> resolve() async {
    calls++;
    return response;
  }
}

String? _dartExecutable() {
  for (final candidate in _dartCandidates()) {
    if (!File(candidate).existsSync()) continue;
    final probe = Process.runSync(candidate, const <String>['--version']);
    if (probe.exitCode == 0) return candidate;
  }
  return null;
}

Iterable<String> _dartCandidates() sync* {
  final path = Platform.environment['PATH'] ?? '';
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    yield '$directory${Platform.pathSeparator}dart';
  }
  final resolved = File(Platform.resolvedExecutable);
  yield '${resolved.parent.parent.parent.parent.path}'
      '${Platform.pathSeparator}dart-sdk'
      '${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}dart';
}
