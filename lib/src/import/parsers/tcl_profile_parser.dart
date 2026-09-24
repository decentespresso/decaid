import 'package:reaprime/src/import/parsers/tcl_parser.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart';

/// de1app's stored `advanced_shot` for these profile types is a snapshot of
/// whatever frames the pressure/flow UI last generated, not an authoritative
/// source -- decaid does not reimplement that generator. Mirrors the same
/// restriction as `tools/ingest_profiles.py`.
class UnsupportedProfileTypeException implements Exception {
  final String profileType;
  const UnsupportedProfileTypeException(this.profileType);

  @override
  String toString() =>
      'Profile type $profileType is not supported for TCL import';
}

class TclProfileParser {
  TclProfileParser._();

  static const _unsupportedTypes = {'settings_2a', 'settings_2b'};

  static ProfileRecord parse(String content) {
    final map = TclParser.parse(content);

    final profileType = map['settings_profile_type']?.toString() ?? '';
    if (_unsupportedTypes.contains(profileType)) {
      throw UnsupportedProfileTypeException(profileType);
    }

    final rawSteps = map['advanced_shot'];
    final steps = rawSteps is String
        ? _parseSteps(rawSteps)
        : <Map<String, dynamic>>[];

    final json = {
      'version': '2',
      'title': _str(map['profile_title']) ?? '',
      'author': _str(map['author']) ?? '',
      'notes': _str(map['profile_notes']) ?? '',
      'beverage_type': _str(map['beverage_type']) ?? 'espresso',
      'steps': steps,
      'tank_temperature': _str(map['tank_desired_water_temperature']) ?? '0',
      'target_weight': _str(map['final_desired_shot_weight_advanced']) ?? '0',
      'target_volume': _str(map['final_desired_shot_volume_advanced']) ?? '0',
      'target_volume_count_start':
          _str(map['final_desired_shot_volume_advanced_count_start']) ?? '0',
    };

    final profile = Profile.fromJson(json);
    return ProfileRecord.create(profile: profile);
  }

  static String? _str(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  // `advanced_shot`'s value is `{frame1} {frame2} ...`; each frame is itself
  // `key value key value ...` with `{...}`-grouped values. Both levels are
  // the same space-separated/brace-grouped shape `TclParser.splitList`
  // already tokenises, so splitting frames and splitting a frame's own
  // fields are the same call one level apart.
  static List<Map<String, dynamic>> _parseSteps(String raw) {
    return TclParser.splitList(
      raw.trim(),
    ).map(_parseFrame).whereType<Map<String, dynamic>>().toList();
  }

  static Map<String, dynamic>? _parseFrame(String frame) {
    final tokens = TclParser.splitList(frame.trim());
    if (tokens.length < 2) return null;

    final raw = <String, String>{};
    for (var i = 0; i + 1 < tokens.length; i += 2) {
      raw[tokens[i]] = tokens[i + 1];
    }

    final pump = raw['pump'] ?? 'pressure';
    final step = <String, dynamic>{
      'name': raw['name'] ?? '',
      'pump': pump,
      'transition': raw['transition'] ?? 'fast',
      'temperature': raw['temperature'] ?? '0',
      'sensor': raw['sensor'] ?? 'coffee',
      'seconds': raw['seconds'] ?? '0',
      'volume': raw['volume'] ?? '0',
      'weight': raw['weight'] ?? '0',
      if (pump == 'flow')
        'flow': raw['flow'] ?? '0'
      else
        'pressure': raw['pressure'] ?? '0',
    };

    final exitIf = (int.tryParse(raw['exit_if'] ?? '0') ?? 0) != 0;
    if (exitIf) {
      final exitFields = const {
        'pressure_over': ('pressure', 'over', 'exit_pressure_over'),
        'pressure_under': ('pressure', 'under', 'exit_pressure_under'),
        'flow_over': ('flow', 'over', 'exit_flow_over'),
        'flow_under': ('flow', 'under', 'exit_flow_under'),
      }[raw['exit_type']];
      if (exitFields != null) {
        step['exit'] = {
          'type': exitFields.$1,
          'condition': exitFields.$2,
          'value': raw[exitFields.$3] ?? '0',
        };
      }
    }

    final maxValue = double.tryParse(raw['max_flow_or_pressure'] ?? '') ?? 0;
    final maxRange =
        double.tryParse(raw['max_flow_or_pressure_range'] ?? '') ?? 0;
    if (maxValue > 0 || maxRange > 0) {
      step['limiter'] = {
        'value': raw['max_flow_or_pressure'] ?? '0',
        'range': raw['max_flow_or_pressure_range'] ?? '0',
      };
    }

    return step;
  }
}
