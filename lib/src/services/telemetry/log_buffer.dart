import 'package:circular_buffer/circular_buffer.dart';

class LogBuffer {
  static const int maxSizeBytes = 16 * 1024;

  final CircularBuffer<String> _buffer = CircularBuffer(500);

  int _currentSizeBytes = 0;

  void append(String message) {
    final timestamped = '[${DateTime.now().toIso8601String()}] $message';
    final entrySize = timestamped.length;

    if (_buffer.isFilled && _buffer.isNotEmpty) {
      final oldestEntry = _buffer.first;
      _currentSizeBytes -= oldestEntry.length;
    }

    _buffer.add(timestamped);
    _currentSizeBytes += entrySize;

    if (_currentSizeBytes > maxSizeBytes && _buffer.isNotEmpty) {
      final entries = _buffer.toList();
      var trimmedSize = _currentSizeBytes;
      var removeCount = 0;

      while (trimmedSize > maxSizeBytes && removeCount < entries.length) {
        trimmedSize -= entries[removeCount].length;
        removeCount++;
      }

      if (removeCount > 0) {
        _buffer.clear();
        for (var i = removeCount; i < entries.length; i++) {
          _buffer.add(entries[i]);
        }
        _currentSizeBytes = trimmedSize;
      }
    }
  }

  String getContents() {
    return _buffer.join('\n');
  }

  void clear() {
    _buffer.clear();
    _currentSizeBytes = 0;
  }

  int get currentSizeBytes => _currentSizeBytes;

  int get entryCount => _buffer.length.toInt();
}
