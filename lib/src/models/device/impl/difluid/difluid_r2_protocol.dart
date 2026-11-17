import 'dart:typed_data';

enum DifluidR2EventKind { ack, status, temperature, reading, error, unknown }

final class DifluidR2Event {
  const DifluidR2Event({
    required this.kind,
    required this.raw,
    this.status,
    this.measuring,
    this.tds,
    this.temperatureC,
    this.refractiveIndex,
    this.error,
    this.package,
  });

  final DifluidR2EventKind kind;
  final Uint8List raw;
  final String? status;
  final bool? measuring;
  final double? tds;
  final double? temperatureC;
  final double? refractiveIndex;
  final String? error;
  final int? package;
}

final class DifluidR2ProtocolException implements Exception {
  const DifluidR2ProtocolException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class DifluidR2Protocol {
  static const int _header1 = 0xDF;
  static const int _header2 = 0xDF;
  static const int _functionDeviceSettings = 0x01;
  static const int _functionDeviceAction = 0x03;
  static const int _commandSetTemperatureUnit = 0x00;
  static const int _commandSingleTest = 0x00;
  static const int _commandKnownError = 0xFE;

  static const Map<int, String> _statusCodes = {
    0: 'finished',
    4: 'average_started',
    5: 'average_ongoing',
    6: 'average_finished',
    9: 'loop_finished',
    11: 'started',
  };

  static const Map<int, String> _errorCodes = {
    3: 'no_liquid',
    4: 'beyond_range',
  };

  static Uint8List setCelsiusCommand() => _buildCommand(
    _functionDeviceSettings,
    _commandSetTemperatureUnit,
    const [0x00],
  );

  static Uint8List singleTestCommand() =>
      _buildCommand(_functionDeviceAction, _commandSingleTest);

  static DifluidR2Event parse(Uint8List raw) {
    if (raw.length < 6) {
      throw const DifluidR2ProtocolException('packet too short');
    }
    if (raw[0] != _header1 || raw[1] != _header2) {
      throw const DifluidR2ProtocolException('invalid packet header');
    }

    final dataLength = raw[4];
    final expectedLength = 2 + 1 + 1 + 1 + dataLength + 1;
    if (raw.length != expectedLength) {
      throw DifluidR2ProtocolException(
        'invalid packet length: got ${raw.length}, expected $expectedLength',
      );
    }
    if (_checksum(raw.sublist(0, raw.length - 1)) != raw.last) {
      throw const DifluidR2ProtocolException('invalid packet checksum');
    }

    final function = raw[2];
    final command = raw[3];
    final data = raw.sublist(5, raw.length - 1);

    if (command == _commandKnownError) {
      return _parseError(raw, data);
    }

    if (function == _functionDeviceSettings || data.isEmpty) {
      return DifluidR2Event(kind: DifluidR2EventKind.ack, raw: raw);
    }

    final package = data[0];
    return switch (package) {
      0x00 => _parseStatus(raw, data),
      0x01 => _parseTemperature(raw, data),
      0x02 => _parseTds(raw, data),
      _ => DifluidR2Event(
        kind: DifluidR2EventKind.unknown,
        raw: raw,
        package: package,
      ),
    };
  }

  static Uint8List _buildCommand(
    int function,
    int command, [
    List<int> data = const [],
  ]) {
    if (data.length > 255) {
      throw ArgumentError('R2 command data is limited to 255 bytes');
    }

    final body = Uint8List.fromList([
      _header1,
      _header2,
      function,
      command,
      data.length,
      ...data,
    ]);
    return Uint8List.fromList([...body, _checksum(body)]);
  }

  static DifluidR2Event _parseStatus(Uint8List raw, Uint8List data) {
    if (data.length < 2) {
      throw const DifluidR2ProtocolException(
        'status packet missing status code',
      );
    }

    final code = data[1];
    final status = _statusCodes[code] ?? 'unknown_$code';
    final measuring = switch (code) {
      4 || 5 || 11 => true,
      0 || 6 || 9 => false,
      _ => null,
    };

    return DifluidR2Event(
      kind: DifluidR2EventKind.status,
      raw: raw,
      package: 0,
      status: status,
      measuring: measuring,
    );
  }

  static DifluidR2Event _parseTemperature(Uint8List raw, Uint8List data) {
    if (data.length < 6) {
      throw const DifluidR2ProtocolException('temperature packet too short');
    }

    final prismX10 = _readUint16(data, 1);
    final tankX10 = _readUint16(data, 3);
    return DifluidR2Event(
      kind: DifluidR2EventKind.temperature,
      raw: raw,
      package: 1,
      temperatureC: (prismX10 + tankX10) / 20.0,
    );
  }

  static DifluidR2Event _parseTds(Uint8List raw, Uint8List data) {
    if (data.length < 3) {
      throw const DifluidR2ProtocolException('TDS packet too short');
    }

    return DifluidR2Event(
      kind: DifluidR2EventKind.reading,
      raw: raw,
      package: 2,
      tds: _readUint16(data, 1).toSigned(16) / 100.0,
      refractiveIndex: data.length >= 7
          ? _readUint32(data, 3) / 100000.0
          : null,
      measuring: false,
    );
  }

  static DifluidR2Event _parseError(Uint8List raw, Uint8List data) {
    var error = 'unknown_error';
    if (data.length >= 2 && data[0] == 0x02) {
      error = _errorCodes[data[1]] ?? 'unknown_error_${data[1]}';
    }
    return DifluidR2Event(
      kind: DifluidR2EventKind.error,
      raw: raw,
      error: error,
      measuring: false,
    );
  }

  static int _readUint16(Uint8List data, int offset) =>
      (data[offset] << 8) | data[offset + 1];

  static int _readUint32(Uint8List data, int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];

  static int _checksum(List<int> data) =>
      data.fold<int>(0, (sum, value) => (sum + value) & 0xFF);
}
