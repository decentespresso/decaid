class Color16 {
  final int red;
  final int green;
  final int blue;

  const Color16(this.red, this.green, this.blue)
    : assert(red >= 0 && red <= 65535),
      assert(green >= 0 && green <= 65535),
      assert(blue >= 0 && blue <= 65535);

  static const off = Color16(0, 0, 0);

  String toJson() => '${_hex4(red)}${_hex4(green)}${_hex4(blue)}';

  static Color16 fromJson(dynamic hex) {
    if (hex is! String || hex.length < 12) return off;
    final r = _hex16(hex, 0);
    final g = _hex16(hex, 4);
    final b = _hex16(hex, 8);
    if (r == null || g == null || b == null) return off;
    return Color16(r.clamp(0, 65535), g.clamp(0, 65535), b.clamp(0, 65535));
  }

  static String _hex4(int v) =>
      v.toRadixString(16).padLeft(4, '0').toUpperCase();

  static int? _hex16(String s, int offset) =>
      int.tryParse(s.substring(offset, offset + 4), radix: 16);

  @override
  bool operator ==(Object other) =>
      other is Color16 &&
      red == other.red &&
      green == other.green &&
      blue == other.blue;

  @override
  int get hashCode => Object.hash(red, green, blue);

  @override
  String toString() => 'Color16(#${toJson()})';
}

class ZoneLedState {
  final Color16 sleeping;
  final Color16 awake;

  const ZoneLedState({this.sleeping = Color16.off, this.awake = Color16.off});

  Map<String, dynamic> toJson() => {
    'sleeping': sleeping.toJson(),
    'awake': awake.toJson(),
  };

  factory ZoneLedState.fromJson(Map<String, dynamic> json) => ZoneLedState(
    sleeping: Color16.fromJson(json['sleeping']),
    awake: Color16.fromJson(json['awake']),
  );

  @override
  bool operator ==(Object other) =>
      other is ZoneLedState &&
      sleeping == other.sleeping &&
      awake == other.awake;

  @override
  int get hashCode => Object.hash(sleeping, awake);

  @override
  String toString() => 'ZoneLedState(sleeping: $sleeping, awake: $awake)';
}

class LedStripState {
  final ZoneLedState frontStrip;
  final ZoneLedState backStrip;
  final ZoneLedState frontSwitch;

  const LedStripState({
    this.frontStrip = const ZoneLedState(),
    this.backStrip = const ZoneLedState(),
    this.frontSwitch = const ZoneLedState(),
  });

  Map<String, dynamic> toJson() => {
    'frontStrip': frontStrip.toJson(),
    'backStrip': backStrip.toJson(),
    'frontSwitch': frontSwitch.toJson(),
  };

  factory LedStripState.fromJson(Map<String, dynamic> json) => LedStripState(
    frontStrip: ZoneLedState.fromJson(
      json['frontStrip'] as Map<String, dynamic>? ?? const {},
    ),
    backStrip: ZoneLedState.fromJson(
      json['backStrip'] as Map<String, dynamic>? ?? const {},
    ),
    frontSwitch: ZoneLedState.fromJson(
      json['frontSwitch'] as Map<String, dynamic>? ?? const {},
    ),
  );

  @override
  bool operator ==(Object other) =>
      other is LedStripState &&
      frontStrip == other.frontStrip &&
      backStrip == other.backStrip &&
      frontSwitch == other.frontSwitch;

  @override
  int get hashCode => Object.hash(frontStrip, backStrip, frontSwitch);

  @override
  String toString() =>
      'LedStripState(frontStrip: $frontStrip, '
      'backStrip: $backStrip, frontSwitch: $frontSwitch)';
}
