part of 'unified_de1.dart';

const _mmrReadTimeout = Duration(seconds: 4);

const _mmrReadRetries = 2;

const _mmrReadRetrySettle = Duration(milliseconds: 300);

extension UnifiedDe1MMR on UnifiedDe1 {
  Future<List<int>> _mmrRead(
    MMRItem item, {
    int length = 0,
    Duration? timeout,
    int? retries,
    Duration? retrySettle,
  }) => _mmrReadRaw(
    item.address,
    length: length,
    label: item.name,
    timeout: timeout,
    retries: retries,
    retrySettle: retrySettle,
  );

  Future<void> _mmrWrite(MMRItem item, List<int> bufferData) =>
      _mmrWriteRaw(item.address, bufferData, label: item.name);

  Future<List<int>> _mmrReadRaw(
    int address, {
    int length = 0,
    String? label,
    Duration? timeout,
    int? retries,
    Duration? retrySettle,
  }) => _firmwareMmrGate.runMmr(
    () => _mmrReadRawPermitted(
      address,
      length: length,
      label: label,
      timeout: timeout,
      retries: retries,
      retrySettle: retrySettle,
    ),
  );

  Future<List<int>> _mmrReadRawPermitted(
    int address, {
    int length = 0,
    String? label,
    Duration? timeout,
    int? retries,
    Duration? retrySettle,
  }) async {
    final logLabel = label ?? '0x${address.toRadixString(16)}';
    final readTimeout = timeout ?? _mmrReadTimeout;
    final readRetries = retries ?? _mmrReadRetries;
    final readRetrySettle = retrySettle ?? _mmrReadRetrySettle;
    ByteData bytes = ByteData(20);
    bytes.setInt32(0, address, Endian.big);
    var buffer = bytes.buffer.asUint8List();
    buffer[0] = (length % 0xFF);

    for (var attempt = 0; ; attempt++) {
      _log.info("mmr read: $logLabel${attempt > 0 ? ' (retry $attempt)' : ''}");
      _log.fine(
        'sending read req ${buffer.map((e) => e.toRadixString(16)).toList()}',
      );

      final responseFuture = _mmr
          .map((d) => d.buffer.asUint8List().toList())
          .firstWhere(
            (element) =>
                buffer[1] == element[1] &&
                buffer[2] == element[2] &&
                buffer[3] == element[3],
            orElse: () => <int>[],
          )
          .timeout(readTimeout, onTimeout: () => <int>[]);

      await _transport.writeWithResponse(
        Endpoint.readFromMMR,
        Uint8List.fromList(buffer),
      );

      final result = await responseFuture;
      if (result.isNotEmpty) {
        _log.info(
          "listen event Result:  ${result.map((e) => e.toRadixString(16)).toList()}",
        );
        return result;
      }

      if (attempt >= readRetries) {
        throw MmrTimeoutException(logLabel, readTimeout);
      }
      _log.warning(
        'mmr read $logLabel timed out (attempt ${attempt + 1} of '
        '${readRetries + 1}), retrying',
      );
      await Future<void>.delayed(readRetrySettle);
    }
  }

  Future<void> _mmrWriteRaw(
    int address,
    List<int> bufferData, {
    String? label,
  }) => _firmwareMmrGate.runMmr(
    () => _mmrWriteRawPermitted(address, bufferData, label: label),
  );

  Future<void> _mmrWriteRawPermitted(
    int address,
    List<int> bufferData, {
    String? label,
  }) async {
    final logLabel = label ?? '0x${address.toRadixString(16)}';
    _log.info("mmr write: $logLabel");

    ByteData bytes = ByteData(20);
    bytes.setInt32(0, address, Endian.big);
    var buffer = bytes.buffer.asUint8List();
    buffer[0] = (bufferData.length % 0xFF);
    var i = 0;
    for (var _ in bufferData) {
      buffer[i + 4] = bufferData[i++];
    }
    _log.fine('payload ${bufferData.map((e) => e.toRadixString(16)).toList()}');
    return _transport.writeWithResponse(
      Endpoint.writeToMMR,
      Uint8List.fromList(buffer),
    );
  }

  int _unpackMMRInt(List<int> buffer) {
    if (buffer.length < 20) {
      throw StateError(
        'MMR response buffer too short (got ${buffer.length} bytes, '
        'expected at least 20)',
      );
    }
    ByteData bytes = ByteData(20);
    var i = 0;
    var list = bytes.buffer.asUint8List();
    for (var _ in list) {
      list[i] = buffer[i++];
    }
    return bytes.getInt32(4, Endian.little);
  }

  /// Decodes the word at [wordIndex] (0-based) from a multi-word MMR
  /// response. Words are little-endian signed int32 values starting at byte
  /// offset 4, one per consecutive register. Throws [StateError] when the
  /// response is too short rather than substituting zero/default values.
  /// Frames longer than 20 bytes decode the words in place without
  /// consuming trailing bytes.
  int _unpackMMRIntAt(List<int> buffer, int wordIndex) {
    final needed = 4 + 4 * (wordIndex + 1);
    if (buffer.length < needed) {
      throw StateError(
        'MMR response buffer too short (got ${buffer.length} bytes, '
        'expected at least $needed for word $wordIndex)',
      );
    }
    ByteData bytes = ByteData(20);
    var list = bytes.buffer.asUint8List();
    final copyable = buffer.length < 20 ? buffer.length : 20;
    for (var i = 0; i < copyable; i++) {
      list[i] = buffer[i];
    }
    return bytes.getInt32(4 + 4 * wordIndex, Endian.little);
  }

  /// Reads [wordCount] consecutive 32-bit words starting at [startAddress]
  /// with a single MMR request (`length` = additional words after the
  /// first) and returns the raw signed words in register order. Uses the
  /// same request/response correlation, serialization gate, retry and
  /// timeout machinery as single-word reads via [_mmrReadRaw].
  Future<List<int>> _mmrReadWords(
    int startAddress, {
    required int wordCount,
    String? label,
  }) async {
    if (wordCount < 1 || wordCount > 4) {
      throw RangeError.range(wordCount, 1, 4, 'wordCount');
    }
    final result = await _mmrReadRaw(
      startAddress,
      length: wordCount - 1,
      label: label ?? '0x${startAddress.toRadixString(16)}',
    );
    return List<int>.generate(
      wordCount,
      (index) => _unpackMMRIntAt(result, index),
    );
  }

  Uint8List _packMMRInt(int number) {
    var bytes = ByteData(4);
    bytes.setUint32(0, number, Endian.little);
    return bytes.buffer.asUint8List();
  }

  Future<int> _readMMRInt(
    MMRItem item, {
    Duration? timeout,
    int? retries,
    Duration? retrySettle,
  }) async {
    final result = await _mmrRead(
      item,
      timeout: timeout,
      retries: retries,
      retrySettle: retrySettle,
    );
    return _unpackMMRInt(result);
  }

  Future<double> _readMMRScaled(
    MMRItem item, {
    Duration? timeout,
    int? retries,
    Duration? retrySettle,
  }) async {
    final rawValue = await _readMMRInt(
      item,
      timeout: timeout,
      retries: retries,
      retrySettle: retrySettle,
    );
    return rawValue.toDouble() * item.readScale;
  }

  Future<void> _writeMMRInt(MMRItem item, int value) async {
    final clampedValue = (item.min != null && item.max != null)
        ? value.clamp(item.min!, item.max!)
        : value;
    await _mmrWrite(item, _packMMRInt(clampedValue));
  }

  int _scaledClampedMMRInt(MMRItem item, double value) {
    final scaledValue = (value * item.writeScale).toInt();
    return (item.min != null && item.max != null)
        ? scaledValue.clamp(item.min!, item.max!)
        : scaledValue;
  }

  Future<void> _writeMMRScaled(MMRItem item, double value) async {
    await _writeMMRInt(item, _scaledClampedMMRInt(item, value));
  }
}
