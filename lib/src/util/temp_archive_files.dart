import 'dart:async';
import 'dart:io';

class TempArchiveDir {
  late final Directory _dir;

  static Future<TempArchiveDir> create(
    String prefix, {
    Directory? parent,
  }) async {
    final result = TempArchiveDir._();
    result._dir = await (parent ?? Directory.systemTemp).createTemp(prefix);
    return result;
  }

  TempArchiveDir._();

  Directory get directory => _dir;

  String get path => _dir.path;

  String filePath(String name) => '${_dir.path}${Platform.pathSeparator}$name';

  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      if (await _dir.exists()) {
        await _dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}

class DeferredFileCleanup {
  final File file;
  final Duration gracePeriod;
  Timer? _timer;

  DeferredFileCleanup(
    this.file, {
    this.gracePeriod = const Duration(minutes: 5),
  });

  void start() {
    _timer ??= Timer(gracePeriod, () {
      file.delete().then((_) {}, onError: (_) {});
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
