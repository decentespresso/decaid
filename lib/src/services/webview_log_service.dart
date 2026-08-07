import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

class WebViewLogService {
  final _log = Logger('WebViewLogService');

  static const int maxFileSizeBytes = 1024 * 1024;

  final String _logDirectoryPath;

  late final File _logFile;

  IOSink? _sink;

  final StreamController<String> _streamController =
      StreamController<String>.broadcast();

  WebViewLogService({required String logDirectoryPath})
    : _logDirectoryPath = logDirectoryPath;

  Stream<String> get stream => _streamController.stream;

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

  void dispose() {
    _sink?.close();
    _sink = null;
    if (!_streamController.isClosed) {
      _streamController.close();
    }
    _log.info('WebViewLogService disposed');
  }
}
