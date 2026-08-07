import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

/// Service for capturing and persisting WebView console output from WebUI skins.
///
/// Writes all console messages to a dedicated `webview_console.log` file,
/// completely isolated from the app's main log pipeline (package:logging).
/// Also provides a broadcast stream for live WebSocket consumers.
///
/// File lifecycle:
/// - Cleared on app restart (initialize)
/// - Capped at 1MB with oldest-half truncation
/// - Entries persist across skin reloads within a session
class WebViewLogService {
  final _log = Logger('WebViewLogService');

  /// Maximum file size in bytes (1MB)
  static const int maxFileSizeBytes = 1024 * 1024;

  /// Path to the log directory (resolved by caller)
  final String _logDirectoryPath;

  /// The log file
  late final File _logFile;

  /// IOSink for efficient appending
  IOSink? _sink;

  /// Broadcast stream controller for live WebSocket consumers
  final StreamController<String> _streamController =
      StreamController<String>.broadcast();

  /// Create a WebViewLogService that writes to the given directory.
  ///
  /// Uses the app documents directory on all platforms.
  WebViewLogService({required String logDirectoryPath})
    : _logDirectoryPath = logDirectoryPath;

  /// Broadcast stream of formatted log entries for WebSocket consumers
  Stream<String> get stream => _streamController.stream;

  /// Initialize the service: create or truncate the log file.
  ///
  /// Must be called before [log]. Clears the file on each app restart
  /// per design decision (fresh log each launch).
  Future<void> initialize() async {
    _logFile = File('$_logDirectoryPath/webview_console.log');

    try {
      final dir = Directory(_logDirectoryPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      await _logFile.writeAsString('');

      _sink = _logFile.openWrite(mode: FileMode.append);

      _log.info('WebViewLogService initialized: ${_logFile.path}');
    } catch (e, st) {
      _log.warning('Failed to initialize WebViewLogService', e, st);
    }
  }

  /// Log a console message from a WebView skin.
  ///
  /// Format: `[ISO8601_TIMESTAMP] [skinId] [LEVEL] message`
  ///
  /// The entry is written to the log file and broadcast to stream consumers.
  /// WebView messages are NOT routed through package:logging to maintain
  /// complete isolation from the app log pipeline and telemetry.
  void log(String skinId, String level, String message) {
    if (_sink == null) return;

    final timestamp = DateTime.now().toIso8601String();
    final formatted = '[$timestamp] [$skinId] [$level] $message';

    _sink!.writeln(formatted);

    if (!_streamController.isClosed) {
      _streamController.add(formatted);
    }

    _checkAndTruncate();
  }

  /// Get the full contents of the log file.
  ///
  /// Used by the REST endpoint to return raw log text.
  /// Returns empty string if file doesn't exist or can't be read.
  String getContents() {
    try {
      if (_logFile.existsSync()) {
        return _logFile.readAsStringSync();
      }
    } catch (e) {
      _log.warning('Failed to read webview log file', e);
    }
    return '';
  }

  /// Check file size and truncate if over the 1MB cap.
  ///
  /// Truncation strategy: keep the second half of the file (most recent entries).
  /// This is infrequent — only triggers when file exceeds 1MB boundary.
  void _checkAndTruncate() {
    try {
      final fileSize = _logFile.lengthSync();
      if (fileSize > maxFileSizeBytes) {
        _log.info(
          'WebView log file exceeds ${maxFileSizeBytes ~/ 1024}KB '
          '($fileSize bytes), truncating...',
        );

        _sink?.close();

        final contents = _logFile.readAsStringSync();
        final halfPoint = contents.length ~/ 2;

        final newlineIndex = contents.indexOf('\n', halfPoint);
        final keepFrom = newlineIndex != -1 ? newlineIndex + 1 : halfPoint;

        _logFile.writeAsStringSync(contents.substring(keepFrom));

        _sink = _logFile.openWrite(mode: FileMode.append);

        _log.info(
          'WebView log file truncated to ${_logFile.lengthSync()} bytes',
        );
      }
    } catch (e) {
      _log.warning('Failed to check/truncate webview log file', e);
    }
  }

  /// Dispose the service: close the file sink and stream controller.
  void dispose() {
    _sink?.close();
    _sink = null;
    if (!_streamController.isClosed) {
      _streamController.close();
    }
    _log.info('WebViewLogService disposed');
  }
}
