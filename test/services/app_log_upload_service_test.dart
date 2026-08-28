import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CredentialStore implements CredentialStore {
  final Map<String, String> values = {};
  bool throwOnRead = false;

  @override
  Future<String?> read({required String key}) async {
    if (throwOnRead) throw StateError('credential read failed');
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

class _BlockingUploadAccountService extends DecentAccountService {
  _BlockingUploadAccountService({
    required super.httpClient,
    required super.credentialStore,
  });

  final uploadStarted = Completer<void>();
  final releaseUpload = Completer<void>();

  @override
  Future<http.Response> uploadAppLogs(
    String body, {
    required bool Function() isAllowed,
    required Duration timeout,
  }) async {
    if (!uploadStarted.isCompleted) {
      uploadStarted.complete();
      await releaseUpload.future;
    }
    return super.uploadAppLogs(body, isAllowed: isAllowed, timeout: timeout);
  }
}

class _AbortAwareClient extends http.BaseClient {
  final aborted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abortable = request as http.AbortableRequest;
    await abortable.abortTrigger;
    aborted.complete();
    throw http.RequestAbortedException(request.url);
  }
}

Future<AppLogUploadResult> upload(
  AppLogUploadService service, {
  DateTime? at,
}) =>
    withClock(Clock.fixed(at ?? DateTime(2026, 8, 27, 12)), service.uploadNow);

void main() {
  late Directory tempDir;
  late _CredentialStore credentials;
  late List<http.Request> requests;
  late int responseStatus;
  late DecentAccountService accountService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('app_log_upload_test');
    credentials = _CredentialStore();
    await credentials.write(key: 'email', value: 'user@example.com');
    await credentials.write(key: 'password', value: 'cryptpw');
    requests = [];
    responseStatus = 200;
    accountService = DecentAccountService(
      httpClient: http_testing.MockClient((request) async {
        requests.add(request);
        return http.Response('ok', responseStatus);
      }),
      credentialStore: credentials,
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  AppLogUploadService buildService({
    AppLogMachineIdentity? identity = const AppLogMachineIdentity(
      serialNumber: '12345',
      firmwareVersion: '1337',
    ),
    int softLimitBytes = 700000,
    int hardLimitBytes = 950000,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration initialDelay = const Duration(days: 1),
    Duration uploadInterval = const Duration(hours: 1),
  }) {
    return AppLogUploadService(
      accountService: accountService,
      logFilePath: '${tempDir.path}${Platform.pathSeparator}log.txt',
      machineIdentity: () => identity,
      initialDelay: initialDelay,
      uploadInterval: uploadInterval,
      softLimitBytes: softLimitBytes,
      hardLimitBytes: hardLimitBytes,
      requestTimeout: requestTimeout,
    );
  }

  test('first upload sends the last 24 hours oldest first', () async {
    await File(
      '${tempDir.path}${Platform.pathSeparator}log.txt.1',
    ).writeAsString(
      '[main] 2026-08-26 10:00:00.000001 INFO Main - ignored\n'
      '[main] 2026-08-26 13:00:00.000001 INFO Main - Rotated first\n'
      'continued detail\n',
    );
    await File('${tempDir.path}${Platform.pathSeparator}log.txt').writeAsString(
      '[main] 2026-08-27 11:00:00.000001 WARNING Main - Live second\n',
    );
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    final result = await upload(service);

    expect(result, AppLogUploadResult.uploaded);
    expect(requests, hasLength(1));
    expect(
      requests.single.url.toString(),
      'https://decentespresso.com/support/api/applog_upload',
    );
    expect(requests.single.method, 'POST');
    expect(requests.single.headers['authorization'], startsWith('Basic '));
    final payload = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(payload['app'], 'decaid');
    expect(payload['sn'], '12345');
    expect(payload['firmwareVersion'], '1337');
    expect(payload['log'], contains('Rotated first\ncontinued detail\n'));
    expect(payload['log'], contains('Live second'));
    expect(payload['log'], isNot(contains('ignored')));
    expect(
      payload['fromTs'],
      DateTime(2026, 8, 26, 12).millisecondsSinceEpoch ~/ 1000,
    );
    expect(
      payload['toTs'],
      DateTime(2026, 8, 27, 11).millisecondsSinceEpoch ~/ 1000,
    );
    expect(await upload(service), AppLogUploadResult.noLogs);
    expect(requests, hasLength(1));
  });

  test('reads rotated logs across missing suffixes', () async {
    await File(
      '${tempDir.path}${Platform.pathSeparator}log.txt.2',
    ).writeAsString(
      '[main] 2026-08-27 09:00:00.000001 INFO Main - older rotated log\n',
    );
    await File('${tempDir.path}${Platform.pathSeparator}log.txt').writeAsString(
      '[main] 2026-08-27 10:00:00.000001 INFO Main - current log\n',
    );
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.uploaded);

    final body = requests.single.body;
    expect(body, contains('older rotated log'));
    expect(
      body.indexOf('older rotated log'),
      lessThan(body.indexOf('current log')),
    );
  });

  test('retries collection when logs rotate before validation', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}log.txt';
    await File(
      '$path.2',
    ).writeAsString('[main] 2026-08-27 08:00:00.000001 INFO Main - oldest\n');
    await File('$path.1').writeAsString(
      '[main] 2026-08-27 09:00:00.000001 INFO Main - unread rotated chunk\n',
    );
    await File(
      path,
    ).writeAsString('[main] 2026-08-27 10:00:00.000001 INFO Main - old live\n');
    var rotations = 0;
    final service = AppLogUploadService(
      accountService: accountService,
      logFilePath: path,
      machineIdentity: () => const AppLogMachineIdentity(
        serialNumber: '12345',
        firmwareVersion: '1337',
      ),
      initialDelay: const Duration(days: 1),
      beforeLogSnapshotValidation: () async {
        if (rotations++ != 0) return;
        await File('$path.2').rename('$path.3');
        await File('$path.1').rename('$path.2');
        await File(path).rename('$path.1');
        await File(path).writeAsString(
          '[main] 2026-08-27 11:00:00.000001 INFO Main - new live\n',
        );
      },
    );
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.uploaded);

    final body = requests.single.body;
    expect(body, contains('unread rotated chunk'));
    expect(body, contains('new live'));
    expect(rotations, 2);
  });

  test('reads native logs with an isolate prefix', () async {
    await File('${tempDir.path}${Platform.pathSeparator}log.txt').writeAsString(
      '[main] 2026-08-27 10:00:00.000001 INFO Main - native log\n',
    );
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.uploaded);
    expect(requests.single.body, contains('native log'));
  });

  test('does not upload while disabled or without a real machine', () async {
    await File(
      '${tempDir.path}${Platform.pathSeparator}log.txt',
    ).writeAsString('[main] 2026-08-27 11:00:00.000001 INFO Main - message\n');
    final disabled = buildService();
    addTearDown(disabled.dispose);
    await disabled.initialize();

    expect(await upload(disabled), AppLogUploadResult.disabled);

    final noMachine = buildService(identity: null);
    addTearDown(noMachine.dispose);
    await noMachine.initialize();
    await noMachine.setEnabled(true);

    expect(await upload(noMachine), AppLogUploadResult.noMachine);
    expect(requests, isEmpty);
  });

  test('keeps the watermark and invalidates auth after rejection', () async {
    await File(
      '${tempDir.path}${Platform.pathSeparator}log.txt',
    ).writeAsString('[main] 2026-08-27 11:00:00.000001 INFO Main - retry me\n');
    responseStatus = 401;
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.rejected);
    expect(await accountService.isAuthKnownInvalid(), isTrue);

    responseStatus = 200;
    expect(await accountService.login('user@example.com', 'password'), isTrue);
    expect(await upload(service), AppLogUploadResult.uploaded);
    final posts = requests
        .where((request) => request.method == 'POST')
        .toList();
    expect(posts, hasLength(2));
    expect(posts[1].body, contains('retry me'));
  });

  test('finishes a timestamp before draining the next chunk', () async {
    final first = '[main] 2026-08-27 10:00:00.000001 INFO Main - ${'a' * 40}';
    final sameSecond =
        '[main] 2026-08-27 10:00:00.900001 INFO Main - ${'b' * 40}';
    final nextSecond =
        '[main] 2026-08-27 10:00:01.000001 INFO Main - ${'c' * 40}';
    await File(
      '${tempDir.path}${Platform.pathSeparator}log.txt',
    ).writeAsString('$first\n$sameSecond\n$nextSecond\n');
    final service = buildService(softLimitBytes: 80, hardLimitBytes: 500);
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.uploaded);
    expect(await upload(service), AppLogUploadResult.uploaded);
    expect(requests, hasLength(2));
    expect(requests[0].body, contains(first));
    expect(requests[0].body, contains(sameSecond));
    expect(requests[0].body, isNot(contains(nextSecond)));
    expect(requests[1].body, contains(nextSecond));
  });

  test('uploads lines appended with the same timestamp', () async {
    final logFile = File('${tempDir.path}${Platform.pathSeparator}log.txt');
    const first =
        '[main] 2026-08-27 10:00:00.000001 INFO Main - first same timestamp';
    const second =
        '[main] 2026-08-27 10:00:00.000001 INFO Main - second same timestamp';
    await logFile.writeAsString('$first\n');
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.uploaded);
    await logFile.writeAsString('$second\n', mode: FileMode.append);
    expect(await upload(service), AppLogUploadResult.uploaded);

    expect(requests, hasLength(2));
    expect(requests[1].body, contains(second));
    expect(requests[1].body, isNot(contains(first)));
  });

  test('re-enabling only shares the previous 24 hours', () async {
    final logFile = File('${tempDir.path}${Platform.pathSeparator}log.txt');
    await logFile.writeAsString(
      '[main] 2026-08-27 11:00:00.000001 INFO Main - before opt out\n',
    );
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);
    expect(await upload(service), AppLogUploadResult.uploaded);

    await service.setEnabled(false);
    await logFile.writeAsString(
      '[main] 2026-08-28 10:00:00.000001 INFO Main - old opt-out log\n'
      '[main] 2026-08-30 11:00:00.000001 INFO Main - recent log\n',
      mode: FileMode.append,
    );
    await service.setEnabled(true);

    expect(
      await upload(service, at: DateTime(2026, 8, 30, 12)),
      AppLogUploadResult.uploaded,
    );
    expect(requests, hasLength(2));
    expect(requests[1].body, isNot(contains('old opt-out log')));
    expect(requests[1].body, contains('recent log'));
  });

  test(
    'disabled startup clears a cursor left by an interrupted opt-out',
    () async {
      SharedPreferences.setMockInitialValues({
        'appLogUpload.enabled': false,
        'appLogUpload.cursor': jsonEncode([
          DateTime(2026, 8, 27, 9).microsecondsSinceEpoch,
          1,
        ]),
      });
      final logFile = File('${tempDir.path}${Platform.pathSeparator}log.txt');
      await logFile.writeAsString(
        '[main] 2026-08-28 10:00:00.000001 INFO Main - old opt-out log\n'
        '[main] 2026-08-30 11:00:00.000001 INFO Main - recent log\n',
      );
      final service = buildService();
      addTearDown(service.dispose);
      await service.initialize();
      await service.setEnabled(true);

      expect(
        await upload(service, at: DateTime(2026, 8, 30, 12)),
        AppLogUploadResult.uploaded,
      );
      expect(requests.single.body, isNot(contains('old opt-out log')));
      expect(requests.single.body, contains('recent log'));
    },
  );

  test('enabled startup without an account persistently opts out', () async {
    SharedPreferences.setMockInitialValues({
      'appLogUpload.enabled': true,
      'appLogUpload.cursor': '[1,0]',
    });
    credentials.values.clear();
    final service = buildService();
    addTearDown(service.dispose);

    await service.initialize();

    final preferences = await SharedPreferences.getInstance();
    expect(service.enabled, isFalse);
    expect(preferences.getBool('appLogUpload.enabled'), isFalse);
    expect(preferences.containsKey('appLogUpload.cursor'), isFalse);
  });

  test(
    'enabled startup fails closed when credentials cannot be read',
    () async {
      SharedPreferences.setMockInitialValues({'appLogUpload.enabled': true});
      credentials.throwOnRead = true;
      final service = buildService();
      addTearDown(service.dispose);

      await service.initialize();

      final preferences = await SharedPreferences.getInstance();
      expect(service.enabled, isFalse);
      expect(preferences.getBool('appLogUpload.enabled'), isFalse);
    },
  );

  test('missing account during preflight persistently opts out', () async {
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);
    credentials.values.clear();

    expect(await upload(service), AppLogUploadResult.notLinked);

    final preferences = await SharedPreferences.getInstance();
    expect(service.enabled, isFalse);
    expect(preferences.getBool('appLogUpload.enabled'), isFalse);
  });

  test('ignores timestamp-shaped text inside continuation lines', () async {
    final logFile = File('${tempDir.path}${Platform.pathSeparator}log.txt');
    const continuation =
        '2030-01-01 00:00:00.000001 remains part of the previous record';
    await logFile.writeAsString(
      '[main] 2026-08-27 10:00:00.000001 INFO Main - first\n'
      '$continuation\n',
    );
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.uploaded);
    await logFile.writeAsString(
      '[main] 2026-08-27 10:00:01.000001 INFO Main - second\n',
      mode: FileMode.append,
    );
    expect(await upload(service), AppLogUploadResult.uploaded);

    expect(requests, hasLength(2));
    expect(requests[0].body, contains(continuation));
    expect(requests[1].body, contains('Main - second'));
  });

  test('ignores log-shaped text inside native continuation lines', () async {
    final logFile = File('${tempDir.path}${Platform.pathSeparator}log.txt');
    const continuation =
        '2030-01-01 00:00:00.000001 INFO Imported - embedded log text';
    await logFile.writeAsString(
      '[main] 2026-08-27 10:00:00.000001 INFO Main - first\n'
      '$continuation\n',
    );
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.uploaded);
    await logFile.writeAsString(
      '[main] 2026-08-27 10:00:01.000001 INFO Main - second\n',
      mode: FileMode.append,
    );
    expect(await upload(service), AppLogUploadResult.uploaded);

    expect(requests, hasLength(2));
    expect(requests[0].body, contains(continuation));
    expect(requests[1].body, contains('Main - second'));
  });

  test('keeps JSON request bodies below one megabyte', () async {
    final escaped = '\\' * 600000;
    await File(
      '${tempDir.path}${Platform.pathSeparator}log.txt',
    ).writeAsString('[main] 2026-08-27 10:00:00.000001 INFO Main - $escaped\n');
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.uploaded);

    expect(utf8.encode(requests.single.body).length, lessThan(1000000));
    expect(requests.single.body, contains('oversized log line truncated'));
  });

  test('does not post after consent changes during an upload', () async {
    final blockingService = _BlockingUploadAccountService(
      httpClient: http_testing.MockClient((request) async {
        requests.add(request);
        return http.Response('ok', 200);
      }),
      credentialStore: credentials,
    );
    accountService = blockingService;
    await File('${tempDir.path}${Platform.pathSeparator}log.txt').writeAsString(
      '[main] 2026-08-27 10:00:00.000001 INFO Main - private log\n',
    );
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    final uploadFuture = upload(service);
    await blockingService.uploadStarted.future;
    await service.setEnabled(false);
    await service.setEnabled(true);
    blockingService.releaseUpload.complete();

    expect(await uploadFuture, AppLogUploadResult.disabled);
    expect(requests, isEmpty);
  });

  test(
    're-enabling during a scheduled upload keeps the new schedule',
    () async {
      final blockingService = _BlockingUploadAccountService(
        httpClient: http_testing.MockClient((request) async {
          requests.add(request);
          return http.Response('ok', 200);
        }),
        credentialStore: credentials,
      );
      accountService = blockingService;
      final timestamp = DateTime.now().toIso8601String().replaceFirst('T', ' ');
      await File(
        '${tempDir.path}${Platform.pathSeparator}log.txt',
      ).writeAsString('[main] $timestamp INFO Main - private log\n');
      final service = buildService(
        initialDelay: const Duration(milliseconds: 50),
        uploadInterval: const Duration(days: 1),
      );
      addTearDown(service.dispose);
      await service.initialize();
      await service.setEnabled(true);
      await blockingService.uploadStarted.future;

      await service.setEnabled(false);
      await service.setEnabled(true);
      blockingService.releaseUpload.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(requests, hasLength(1));
    },
  );

  test('turns preflight errors into retryable failures', () async {
    await File('${tempDir.path}${Platform.pathSeparator}log.txt').writeAsString(
      '[main] 2026-08-27 10:00:00.000001 INFO Main - retry later\n',
    );
    final service = buildService();
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);
    credentials.throwOnRead = true;

    expect(await upload(service), AppLogUploadResult.failed);
    expect(service.uploading, isFalse);
  });

  test('aborts stalled requests before reporting failure', () async {
    final client = _AbortAwareClient();
    accountService = DecentAccountService(
      httpClient: client,
      credentialStore: credentials,
    );
    await File('${tempDir.path}${Platform.pathSeparator}log.txt').writeAsString(
      '[main] 2026-08-27 10:00:00.000001 INFO Main - stalled request\n',
    );
    final service = buildService(requestTimeout: Duration.zero);
    addTearDown(service.dispose);
    await service.initialize();
    await service.setEnabled(true);

    expect(await upload(service), AppLogUploadResult.failed);
    expect(client.aborted.isCompleted, isTrue);
    expect(service.uploading, isFalse);
  });
}
