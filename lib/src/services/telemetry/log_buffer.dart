import 'package:circular_buffer/circular_buffer.dart';

/// Rolling circular buffer for log messages with size-based eviction
///
/// Maintains a maximum of 16kb of log messages. Older messages are
/// automatically evicted when the buffer exceeds this size.
/// Each message is timestamped for context.
class LogBuffer {
  /// Maximum size in bytes (16kb)
  static const int maxSizeBytes = 16 * 1024;

  /// Circular buffer with initial capacity
  /// Average 32 bytes/message * 500 = ~16kb
  final CircularBuffer<String> _buffer = CircularBuffer(500);

  /// Current size in bytes of all buffered messages
  int _currentSizeBytes = 0;

  /// Append a message to the buffer with automatic timestamp
  ///
  /// If adding this message would exceed [maxSizeBytes], the oldest
  /// messages are evicted until the buffer is under the limit.
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

  /// Get all buffered log messages as a single string
  ///
  /// Messages are joined with newlines and ordered from oldest to newest.
  String getContents() {
    return _buffer.join('\n');
  }

  /// Clear all buffered messages
  void clear() {
    _buffer.clear();
    _currentSizeBytes = 0;
  }

  /// Get current buffer size in bytes
  int get currentSizeBytes => _currentSizeBytes;

  /// Get number of entries in buffer
  int get entryCount => _buffer.length.toInt();
}
