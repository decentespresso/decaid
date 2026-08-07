part of '../webserver_service.dart';

class LogsHandler {
  final String _logFilePath;
  final int _defaultTailBytes;
  final int _maxTailBytes;

  static const int defaultTailKb = 1024;

  static const int maxTailKb = 4096;

  LogsHandler({
    required String logFilePath,
    int defaultTailKb = LogsHandler.defaultTailKb,
    int maxTailKb = LogsHandler.maxTailKb,
  }) : _logFilePath = logFilePath,
       _defaultTailBytes = defaultTailKb * 1024,
       _maxTailBytes = maxTailKb * 1024;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/logs', _handleGetLogs);
  }

  Future<Response> _handleGetLogs(Request request) async {
    final order = _parseLogOrder(request);
    if (order == null) {
      return Response.badRequest(body: "order must be 'asc' or 'desc'");
    }

    var maxBytes = _defaultTailBytes;
    final kbParam = request.url.queryParameters['kb'];
    if (kbParam != null) {
      final kb = int.tryParse(kbParam);
      if (kb == null || kb <= 0) {
        return Response.badRequest(body: 'kb must be a positive integer');
      }
      maxBytes = min(kb * 1024, _maxTailBytes);
    }

    final files = await _logFilesOldestToNewest();
    if (files.isEmpty) {
      return Response.notFound('Log file not found');
    }

    final window = await _tailWindow(files, maxBytes);
    if (order == _LogOrder.ascending) {
      return Response.ok(
        _streamSegments(window),
        headers: {'content-type': 'text/plain'},
      );
    }
    final contents = await _readSegments(window);
    return Response.ok(
      _reverseLogLines(contents),
      headers: {'content-type': 'text/plain'},
    );
  }

  Future<List<File>> _logFilesOldestToNewest() async {
    final rotated = <File>[];
    for (var i = 1; ; i++) {
      final file = File('$_logFilePath.$i');
      if (!await file.exists()) break;
      rotated.add(file);
    }
    final live = File(_logFilePath);
    return [...rotated.reversed, if (await live.exists()) live];
  }

  Future<List<_FileSegment>> _tailWindow(List<File> files, int maxBytes) async {
    var remaining = maxBytes;
    final segments = <_FileSegment>[];
    for (final file in files.reversed) {
      if (remaining <= 0) break;
      final length = await file.length();
      final start = length > remaining ? length - remaining : 0;
      if (length > start) {
        segments.add(_FileSegment(file, start, length));
      }
      remaining -= length - start;
    }
    return segments.reversed.toList();
  }

  Stream<List<int>> _streamSegments(List<_FileSegment> segments) async* {
    for (final segment in segments) {
      yield* segment.file.openRead(segment.start, segment.end);
    }
  }

  Future<String> _readSegments(List<_FileSegment> segments) async {
    final buffer = BytesBuilder(copy: false);
    for (final segment in segments) {
      await for (final chunk in segment.file.openRead(
        segment.start,
        segment.end,
      )) {
        buffer.add(chunk);
      }
    }
    return utf8.decode(buffer.takeBytes(), allowMalformed: true);
  }
}

class _FileSegment {
  final File file;
  final int start;
  final int end;

  _FileSegment(this.file, this.start, this.end);
}

enum _LogOrder { ascending, descending }

_LogOrder? _parseLogOrder(Request request) {
  final raw = request.url.queryParameters['order'];
  if (raw == null) return _LogOrder.descending;
  switch (raw.toLowerCase()) {
    case 'asc':
      return _LogOrder.ascending;
    case 'desc':
      return _LogOrder.descending;
    default:
      return null;
  }
}

String _orderLogLines(String contents, _LogOrder order) {
  return order == _LogOrder.ascending ? contents : _reverseLogLines(contents);
}

String _reverseLogLines(String contents) {
  final lines = const LineSplitter().convert(contents);
  if (lines.isEmpty) return contents;
  return '${lines.reversed.join('\n')}\n';
}
