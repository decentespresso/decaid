import 'dart:convert';

class HdsWifiCommands {
  HdsWifiCommands._();

  static const rate10k = 'rate 10k';
  static const eventsOn = 'events on';
  static const status = 'status';
  static const tare = 'tare';
  static const timerStart = 'timer start';
  static const timerStop = 'timer stop';
  static const timerReset = 'timer reset';
  static const displayOn = 'display on';
  static const displayOff = 'display off';

  static const handshake = [rate10k, eventsOn, status];
}

class HdsWifiFrame {
  final String? type;

  final double? grams;

  final int? batteryPercent;

  final bool? charging;

  final bool? timerRunning;

  final Map<String, dynamic> raw;

  HdsWifiFrame({
    this.type,
    this.grams,
    this.batteryPercent,
    this.charging,
    this.timerRunning,
    required this.raw,
  });

  bool get hasWeight => grams != null;

  bool get isStatus => type == 'status';

  bool get confirmsHds => grams != null || type == 'status';

  bool get isPowerOff => type == 'power' && raw['event'] == 'power_off';

  static HdsWifiFrame? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final type = decoded['type'];
    final charging = decoded['charging'];
    final timerRunning = decoded['timer_running'];
    return HdsWifiFrame(
      type: type is String ? type : null,
      grams: _toDouble(decoded['grams']),
      batteryPercent: _toInt(decoded['battery_percent']),
      charging: charging is bool ? charging : null,
      timerRunning: timerRunning is bool ? timerRunning : null,
      raw: decoded,
    );
  }

  static double? _toDouble(dynamic v) =>
      v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

  static int? _toInt(dynamic v) =>
      v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
}
