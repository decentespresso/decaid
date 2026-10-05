import 'device.dart';

enum GrinderState { idle, grinding, error, unknown }

enum GrinderCapability { startStop, grindSetting, rpmControl }

class GrinderControlDescriptor {
  final String kind;
  final num? min;
  final num? max;
  final num? step;
  final List<String>? values;

  const GrinderControlDescriptor._(
    this.kind,
    this.min,
    this.max,
    this.step,
    this.values,
  );

  factory GrinderControlDescriptor.fromJson(String control, dynamic json) {
    if (!const {'grindSetting', 'rpmControl'}.contains(control) ||
        json is! Map ||
        json.keys.any((key) => key is! String) ||
        json['kind'] is! String) {
      throw const FormatException('Invalid Grinder control descriptor');
    }
    final kind = json['kind'] as String;
    if (control == 'grindSetting' && kind == 'opaque' && json.length == 1) {
      return const GrinderControlDescriptor._('opaque', null, null, null, null);
    }
    if (control == 'grindSetting' &&
        kind == 'enumerated' &&
        json.keys.every(const {'kind', 'values'}.contains) &&
        json.length == 2 &&
        json['values'] is List &&
        (json['values'] as List).isNotEmpty &&
        (json['values'] as List).every((value) => value is String) &&
        (json['values'] as List).toSet().length ==
            (json['values'] as List).length) {
      return GrinderControlDescriptor._(
        'enumerated',
        null,
        null,
        null,
        List<String>.unmodifiable(json['values'] as List),
      );
    }
    final min = json['min'];
    final max = json['max'];
    final step = json['step'];
    if (kind != 'numeric' ||
        !json.containsKey('min') ||
        !json.containsKey('max') ||
        json.keys.any(
          (key) => !const {'kind', 'min', 'max', 'step'}.contains(key),
        ) ||
        min is! num ||
        max is! num ||
        !min.isFinite ||
        !max.isFinite ||
        min > max ||
        (json.containsKey('step') &&
            (step is! num || !step.isFinite || step <= 0)) ||
        (control == 'rpmControl' &&
            (min is! int ||
                max is! int ||
                min < 0 ||
                (step != null && step is! int)))) {
      throw const FormatException('Invalid Grinder control descriptor');
    }
    return GrinderControlDescriptor._('numeric', min, max, step, null);
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (step != null) 'step': step,
    if (values != null) 'values': values,
  };

  bool acceptsSetting(String setting) {
    if (kind == 'opaque') return true;
    if (kind == 'enumerated') return values!.contains(setting);
    final parsed = num.tryParse(setting);
    return parsed != null &&
        parsed.isFinite &&
        parsed >= min! &&
        parsed <= max!;
  }

  bool acceptsRpm(int rpm) => rpm >= min! && rpm <= max!;
}

abstract class GrinderDevice extends Device {
  Set<GrinderCapability> get capabilities;
  Map<String, GrinderControlDescriptor> get controls => const {};
  List<Map<String, String>> get surfaces => const [];
  bool get hasSurfaceDeclarations => false;
  Stream<GrinderSnapshot> get currentSnapshot;

  Future<void> start();
  Future<void> stop();
  Future<void> setGrindSetting(String setting);
  Future<void> setRpm(int rpm);
}

class GrinderSnapshot {
  final DateTime timestamp;
  final GrinderState state;
  final String? setting;
  final int? rpm;

  const GrinderSnapshot({
    required this.timestamp,
    required this.state,
    this.setting,
    this.rpm,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'state': state.name,
    if (setting != null) 'setting': setting,
    if (rpm != null) 'rpm': rpm,
  };
}

class GrinderOperationException implements Exception {
  final String message;
  final String code;

  const GrinderOperationException(
    this.message, {
    this.code = 'grinder_operation_error',
  });

  @override
  String toString() => message;
}
