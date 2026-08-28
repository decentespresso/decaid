import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class AppLogMachineIdentity {
  const AppLogMachineIdentity({
    required this.serialNumber,
    required this.firmwareVersion,
  });

  final String serialNumber;
  final String firmwareVersion;
}

enum AppLogUploadResult {
  uploaded,
  disabled,
  notLinked,
  noMachine,
  noLogs,
  rejected,
  failed,
}

final class AppLogUploadService extends ChangeNotifier {
  AppLogUploadService({
    required DecentAccountService accountService,
    required AccountConsentStore consentStore,
    required String logFilePath,
    required AppLogMachineIdentity? Function() machineIdentity,
    SharedPreferences? preferences,
    this.initialDelay = const Duration(minutes: 1),
    this.uploadInterval = const Duration(hours: 1),
    this.backlogDelay = const Duration(minutes: 1),
    this.requestTimeout = const Duration(seconds: 30),
    this.softLimitBytes = 700000,
    this.hardLimitBytes = 950000,
    @visibleForTesting this.beforeLogSnapshotValidation,
  }) : _accountService = accountService,
       _consentStore = consentStore,
       _logFilePath = logFilePath,
       _machineIdentity = machineIdentity,
       _preferences = preferences;

  static const _consentKey = 'appLogUpload';
  static const _cursorKey = 'appLogUpload.cursor';
  static const _lastResultKey = 'appLogUpload.lastResult';
  static const _requestLimitBytes = 1000000;
  static const _maxRotatedFiles = 10;
  static const _truncatedLineSuffix = ' [oversized log line truncated]\n';

  static final _timestampPattern = RegExp(
    r'^\[[^\r\n]*\]\s+'
    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,6})?)\s+'
    r'(?:ALL|FINEST|FINER|FINE|CONFIG|INFO|WARNING|SEVERE|SHOUT|OFF)\s+'
    r'.*\s-\s',
  );

  final DecentAccountService _accountService;
  final AccountConsentStore _consentStore;
  final String _logFilePath;
  final AppLogMachineIdentity? Function() _machineIdentity;
  SharedPreferences? _preferences;
  final Logger _log = Logger('AppLogUploadService');

  final Duration initialDelay;
  final Duration uploadInterval;
  final Duration backlogDelay;
  final Duration requestTimeout;
  final int softLimitBytes;
  final int hardLimitBytes;
  final Future<void> Function()? beforeLogSnapshotValidation;

  Timer? _timer;
  Future<AppLogUploadResult>? _uploadFuture;
  bool _enabled = false;
  bool _uploading = false;
  bool _morePending = false;
  bool _disposed = false;
  int _consentGeneration = 0;
  String? _lastResult;

  SharedPreferences get _prefs => _preferences!;

  bool get enabled => _enabled;
  bool get uploading => _uploading;
  String? get lastResult => _lastResult;

  Future<void> initialize() async {
    _preferences ??= await SharedPreferences.getInstance();
    try {
      _enabled =
          await _consentStore.read(_consentKey) ==
          AccountConsentDecision.allowed;
    } catch (error, stackTrace) {
      _enabled = false;
      _log.warning('Failed to read app log sharing consent', error, stackTrace);
    }
    _lastResult = _prefs.getString(_lastResultKey);
    if (_enabled) {
      var linked = false;
      try {
        linked = await _accountService.hasLinkedAccount();
      } catch (error, stackTrace) {
        _log.warning('Failed to read linked account', error, stackTrace);
      }
      if (linked) {
        _schedule(initialDelay);
      } else {
        await setEnabled(false);
      }
    } else if (_prefs.containsKey(_cursorKey)) {
      await _prefs.remove(_cursorKey);
    }
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    if (value) {
      await _consentStore.write(_consentKey, AccountConsentDecision.allowed);
    }
    _consentGeneration++;
    _enabled = value;
    _morePending = false;
    if (value) {
      _schedule(initialDelay);
    } else {
      _timer?.cancel();
      _timer = null;
    }
    _notify();
    if (!value) {
      await _consentStore.write(_consentKey, AccountConsentDecision.denied);
      await _prefs.remove(_cursorKey);
    }
  }

  Future<AppLogUploadResult> uploadNow() async {
    final active = _uploadFuture;
    if (active != null) return active;
    final future = _upload();
    _uploadFuture = future;
    try {
      final result = await future;
      if (_morePending) _schedule(backlogDelay);
      return result;
    } finally {
      if (identical(_uploadFuture, future)) _uploadFuture = null;
    }
  }

  Future<AppLogUploadResult> _upload() async {
    _uploading = true;
    _notify();
    try {
      return await _performUpload();
    } catch (error, stackTrace) {
      _log.warning('App log upload failed', error, stackTrace);
      try {
        await _setLastResult('Upload failed; Decaid will retry later');
      } catch (storageError, storageStackTrace) {
        _log.warning(
          'Failed to save app log upload result',
          storageError,
          storageStackTrace,
        );
      }
      return AppLogUploadResult.failed;
    } finally {
      _uploading = false;
      _notify();
    }
  }

  Future<AppLogUploadResult> _performUpload() async {
    final consentGeneration = _consentGeneration;
    bool uploadAllowed() => _enabled && consentGeneration == _consentGeneration;
    _morePending = false;
    if (!uploadAllowed()) return AppLogUploadResult.disabled;
    if (!await _accountService.hasLinkedAccount()) {
      await setEnabled(false);
      await _setLastResult('Link a Decent account before uploading logs');
      return AppLogUploadResult.notLinked;
    }
    if (await _accountService.isAuthKnownInvalid()) {
      await _setLastResult('Account authentication was rejected');
      return AppLogUploadResult.rejected;
    }
    final identity = _machineIdentity();
    if (identity == null ||
        identity.serialNumber.isEmpty ||
        identity.serialNumber == '0') {
      await _setLastResult('Connect a real machine before uploading logs');
      return AppLogUploadResult.noMachine;
    }

    final now = clock.now();
    final cursor = _readCursor(now);
    final batch = await _collectStableLogs(cursor);
    if (batch.count == 0) {
      await _setLastResult('No new logs to upload');
      return AppLogUploadResult.noLogs;
    }
    if (!uploadAllowed()) return AppLogUploadResult.disabled;

    final body = jsonEncode({
      'app': 'decaid',
      'appVersion': BuildInfo.version,
      'sn': identity.serialNumber,
      'firmwareVersion': identity.firmwareVersion,
      'uploadedAt': now.millisecondsSinceEpoch ~/ 1000,
      'fromTs': cursor.timestampMicros ~/ Duration.microsecondsPerSecond,
      'toTs': batch.cursor.timestampMicros ~/ Duration.microsecondsPerSecond,
      'log': batch.text,
    });
    if (utf8.encode(body).length >= _requestLimitBytes) {
      await _setLastResult('Upload failed because the request is too large');
      return AppLogUploadResult.failed;
    }

    try {
      final response = await _accountService.uploadAppLogs(
        body,
        isAllowed: uploadAllowed,
        timeout: requestTimeout,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (!uploadAllowed()) return AppLogUploadResult.disabled;
        await _saveCursor(batch.cursor);
        if (!uploadAllowed()) {
          await _prefs.remove(_cursorKey);
          return AppLogUploadResult.disabled;
        }
        _morePending = batch.capped;
        final details = [
          if (batch.truncated) 'oversized line truncated',
          if (batch.capped) 'more pending',
        ];
        final suffix = details.isEmpty ? '' : ' (${details.join(', ')})';
        await _setLastResult('Uploaded ${batch.count} lines$suffix');
        _log.info('Uploaded ${batch.count} app log lines$suffix');
        return AppLogUploadResult.uploaded;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        await _setLastResult('Upload rejected (HTTP ${response.statusCode})');
        return AppLogUploadResult.rejected;
      }
      await _setLastResult('Upload failed (HTTP ${response.statusCode})');
      return AppLogUploadResult.failed;
    } on StateError {
      if (!uploadAllowed()) return AppLogUploadResult.disabled;
      await _setLastResult('Link a valid Decent account before uploading logs');
      return AppLogUploadResult.notLinked;
    }
  }

  Future<_AppLogBatch> _collectStableLogs(_AppLogCursor cursor) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final before = await _rotatedLogGeneration();
      final batch = await _collectLogs(cursor);
      await beforeLogSnapshotValidation?.call();
      final after = await _rotatedLogGeneration();
      if (listEquals(before, after)) return batch;
    }
    throw StateError('Log files kept rotating during collection');
  }

  Future<List<Object>> _rotatedLogGeneration() async {
    final generation = <Object>[];
    for (var i = 1; i <= _maxRotatedFiles; i++) {
      final file = File('$_logFilePath.$i');
      final stat = await file.stat();
      generation.add((
        path: file.path,
        type: stat.type,
        size: stat.size,
        modified: stat.modified.microsecondsSinceEpoch,
        changed: stat.changed.microsecondsSinceEpoch,
      ));
    }
    return generation;
  }

  Future<_AppLogBatch> _collectLogs(_AppLogCursor cursor) async {
    final output = StringBuffer();
    var bytes = 0;
    var count = 0;
    var batchCursor = cursor;
    int? currentTimestamp;
    var linesAtTimestamp = 0;
    int? cappedAtSecond;
    var capped = false;
    var truncated = false;
    var stop = false;

    for (final file in await _orderedLogFiles()) {
      final lines = file
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
      await for (final line in lines) {
        final timestamp = _lineTimestamp(line);
        if (timestamp != null && timestamp != currentTimestamp) {
          currentTimestamp = timestamp;
          linesAtTimestamp = 0;
        }
        final effectiveTimestamp = currentTimestamp;
        if (effectiveTimestamp == null) continue;
        linesAtTimestamp++;
        if (effectiveTimestamp < cursor.timestampMicros ||
            (effectiveTimestamp == cursor.timestampMicros &&
                linesAtTimestamp <= cursor.linesAtTimestamp)) {
          continue;
        }
        if (cappedAtSecond != null &&
            effectiveTimestamp ~/ Duration.microsecondsPerSecond !=
                cappedAtSecond) {
          stop = true;
          break;
        }
        final encodedLineBytes = _jsonContentBytes('$line\n');
        if (bytes + encodedLineBytes > hardLimitBytes) {
          if (count == 0) {
            final shortened = _truncateLine(line, hardLimitBytes);
            output.write(shortened);
            bytes = _jsonContentBytes(shortened);
            count++;
            batchCursor = _AppLogCursor(
              timestampMicros: effectiveTimestamp,
              linesAtTimestamp: linesAtTimestamp,
            );
            truncated = true;
          }
          capped = true;
          stop = true;
          break;
        }
        output.writeln(line);
        bytes += encodedLineBytes;
        count++;
        batchCursor = _AppLogCursor(
          timestampMicros: effectiveTimestamp,
          linesAtTimestamp: linesAtTimestamp,
        );
        if (cappedAtSecond == null && bytes >= softLimitBytes) {
          cappedAtSecond = effectiveTimestamp ~/ Duration.microsecondsPerSecond;
          capped = true;
        }
      }
      if (stop) break;
    }

    return _AppLogBatch(
      text: output.toString(),
      cursor: batchCursor,
      count: count,
      capped: capped,
      truncated: truncated,
    );
  }

  int _jsonContentBytes(String value) =>
      utf8.encode(jsonEncode(value)).length - 2;

  String _truncateLine(String line, int limitBytes) {
    var low = 0;
    var high = line.length;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      final candidate = '${line.substring(0, middle)}$_truncatedLineSuffix';
      if (_jsonContentBytes(candidate) <= limitBytes) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    var end = low;
    if (end > 0 && end < line.length) {
      final lastCodeUnit = line.codeUnitAt(end - 1);
      if (lastCodeUnit >= 0xd800 && lastCodeUnit <= 0xdbff) end--;
    }
    return '${line.substring(0, end)}$_truncatedLineSuffix';
  }

  Future<List<File>> _orderedLogFiles() async {
    final rotated = <File>[];
    for (var i = _maxRotatedFiles; i >= 1; i--) {
      final file = File('$_logFilePath.$i');
      if (await file.exists()) rotated.add(file);
    }
    final live = File(_logFilePath);
    return [...rotated, if (await live.exists()) live];
  }

  int? _lineTimestamp(String line) {
    final match = _timestampPattern.firstMatch(line);
    if (match == null) return null;
    final parsed = DateTime.tryParse(match.group(1)!);
    return parsed?.microsecondsSinceEpoch;
  }

  _AppLogCursor _readCursor(DateTime now) {
    final stored = _prefs.getString(_cursorKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is List &&
            decoded.length == 2 &&
            decoded[0] is int &&
            decoded[1] is int &&
            decoded[0] as int > 0 &&
            decoded[1] as int >= 0) {
          return _AppLogCursor(
            timestampMicros: decoded[0] as int,
            linesAtTimestamp: decoded[1] as int,
          );
        }
      } catch (_) {}
    }
    return _AppLogCursor(
      timestampMicros: now
          .subtract(const Duration(hours: 24))
          .microsecondsSinceEpoch,
      linesAtTimestamp: 0,
    );
  }

  Future<void> _saveCursor(_AppLogCursor cursor) => _prefs.setString(
    _cursorKey,
    jsonEncode([cursor.timestampMicros, cursor.linesAtTimestamp]),
  );

  Future<void> _setLastResult(String value) async {
    _lastResult = value;
    await _prefs.setString(_lastResultKey, value);
    _notify();
  }

  void _schedule(Duration delay) {
    if (_disposed || !_enabled) return;
    _timer?.cancel();
    _timer = Timer(delay, _tick);
  }

  Future<void> _tick() async {
    _timer = null;
    try {
      await uploadNow();
    } catch (error, stackTrace) {
      _log.warning('Scheduled app log upload failed', error, stackTrace);
    }
    if (_timer == null && !_morePending) _schedule(uploadInterval);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

final class _AppLogBatch {
  const _AppLogBatch({
    required this.text,
    required this.cursor,
    required this.count,
    required this.capped,
    required this.truncated,
  });

  final String text;
  final _AppLogCursor cursor;
  final int count;
  final bool capped;
  final bool truncated;
}

final class _AppLogCursor {
  const _AppLogCursor({
    required this.timestampMicros,
    required this.linesAtTimestamp,
  });

  final int timestampMicros;
  final int linesAtTimestamp;
}
