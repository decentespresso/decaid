part of '../webserver_service.dart';

/// REST API handler for log file access
///
/// GET /api/v1/logs?kb=N — returns the most recent N kilobytes of the app
/// log. The live log file and any rotated siblings the appender leaves behind
/// (`log.txt.1`, `log.txt.2`, …) are always stitched in true chronological
/// order — oldest rotation first, live file last — before the window is
/// applied.
///
/// The window is size-bounded in all cases: `kb` when given (clamped to
/// [maxTailKb]), [defaultTailKb] otherwise. A full rotation set can reach
/// tens of MB (10 MB per file × keepRotateCount + live), which
/// memory-constrained tablets cannot afford to buffer, so the whole set is
/// never read at once.
///
/// Lines are served newest-first by default. Pass `order=asc` to get the
/// original on-disk chronological order; `asc` responses are streamed
/// straight from the file byte ranges without buffering the window.
/// `order=desc` (the explicit form of the default) must reverse lines, so it
/// buffers the window — the clamp is what keeps that buffer bounded.
class LogsHandler {
  final String _logFilePath;
  final int _defaultTailBytes;
  final int _maxTailBytes;

  /// Tail window in KB when the request has no `kb` (1 MB).
  static const int defaultTailKb = 1024;

  /// Hard ceiling in KB an explicit `kb` is clamped to (4 MB).
  static const int maxTailKb = 4096;

  /// Caps are injectable so tests can exercise the windowing with small files.
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

  /// The live log file plus any rotated siblings, ordered oldest-first so
  /// their concatenation reads chronologically. Empty when no log files exist.
  ///
  /// Rotation naming mirrors `RotatingFileAppender`: rotation 0 is the base
  /// path (newest), higher numbers are progressively older (`log.txt.1`,
  /// `log.txt.2`, …). We probe upward until a rotation is missing, so the set
  /// stays in sync with whatever `keepRotateCount` the appender uses without
  /// this handler needing to know it.
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

  /// The byte ranges, oldest-first, that make up the most recent [maxBytes]
  /// bytes across [files] (given oldest-first).
  ///
  /// Files are measured newest-first until the budget is filled, so older
  /// rotations that fall wholly outside the window are never opened. As with
  /// any byte-tail, the cut can slice the oldest returned line (or a
  /// multi-byte character) mid-way.
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

  /// Stream [segments] to the client without buffering them in memory.
  Stream<List<int>> _streamSegments(List<_FileSegment> segments) async* {
    for (final segment in segments) {
      yield* segment.file.openRead(segment.start, segment.end);
    }
  }

  /// Read [segments] into one string, for responses that must be transformed
  /// whole (line reversal). Callers keep the window capped so this buffer
  /// stays bounded. A window cut mid-character decodes to U+FFFD rather than
  /// throwing.
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

/// A byte range `[start, end)` of one log file inside the served tail window.
class _FileSegment {
  final File file;
  final int start;
  final int end;

  _FileSegment(this.file, this.start, this.end);
}

/// Output line order for the log endpoints.
enum _LogOrder {
  /// Original on-disk order: oldest entries first.
  ascending,

  /// Newest entries first (the default).
  descending,
}

/// Parse the optional `order` query parameter shared by the log endpoints.
///
/// Accepts `desc` (newest-first, the default when absent) or `asc`
/// (oldest-first, the original on-disk order), case-insensitive. Returns `null`
/// for an unrecognized value so the caller can reject it with `400`.
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

/// Apply [order] to raw, chronological log [contents].
///
/// [_LogOrder.ascending] returns the text unchanged; [_LogOrder.descending]
/// reverses it to newest-first via [_reverseLogLines]. Shared by [LogsHandler]
/// and [WebViewLogsHandler], which are both `part of` the webserver library.
String _orderLogLines(String contents, _LogOrder order) {
  return order == _LogOrder.ascending ? contents : _reverseLogLines(contents);
}

/// Reverse the line order of [contents] so the newest log entries appear first.
///
/// Log files are written oldest-first; the REST log endpoints serve them
/// newest-first by default for readability.
///
/// Uses [LineSplitter] so `\n`, `\r\n`, and `\r` terminators are handled and a
/// trailing newline doesn't produce a leading blank line after reversal.
String _reverseLogLines(String contents) {
  final lines = const LineSplitter().convert(contents);
  if (lines.isEmpty) return contents;
  return '${lines.reversed.join('\n')}\n';
}
