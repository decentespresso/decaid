import 'package:reaprime/src/import/parsers/tcl_parser.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart';

class UnsupportedProfileTypeException implements Exception {
  final String profileType;
  const UnsupportedProfileTypeException(this.profileType);

  @override
  String toString() =>
      'Profile type $profileType is not supported for TCL import';
}

class UnsupportedBeverageTypeException implements Exception {
  final String beverageType;
  const UnsupportedBeverageTypeException(this.beverageType);

  @override
  String toString() =>
      'Beverage type $beverageType is not supported for TCL import';
}

class MalformedProfileFrameException implements Exception {
  const MalformedProfileFrameException();

  @override
  String toString() => 'Malformed advanced_shot frame while importing profile';
}

class TclProfileParser {
  TclProfileParser._();

  static const _profileTypeAliases = {
    'settings_2': 'settings_2a',
    'settings_profile_pressure': 'settings_2a',
    'settings_profile_flow': 'settings_2b',
    'settings_profile_advanced': 'settings_2c',
    'settings_2c2': 'settings_2c',
  };
  static const _supportedProfileType = 'settings_2c';

  static const _beverageTypeAliases = {
    'filter': 'pourover',
    'tea': 'pourover',
    'tea_portafilter': 'pourover',
    'descale': 'cleaning',
  };

  static ProfileRecord parse(String content) {
    final map = TclParser.parse(content);

    final rawProfileType = map['settings_profile_type']?.toString() ?? '';
    final profileType = _profileTypeAliases[rawProfileType] ?? rawProfileType;
    if (profileType != _supportedProfileType) {
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
      'beverage_type': _resolveBeverageType(_str(map['beverage_type'])),
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

  static String _resolveBeverageType(String? raw) {
    final value = raw ?? 'espresso';
    final mapped = _beverageTypeAliases[value] ?? value;
    if (!BeverageType.values.any((type) => type.name == mapped)) {
      throw UnsupportedBeverageTypeException(value);
    }
    return mapped;
  }

  static String? _str(dynamic value) {
    if (value == null) return null;
    final s = _flatten(value).trim();
    return s.isEmpty ? null : s;
  }

  static String _flatten(dynamic value) {
    if (value is Map) {
      return value.entries
          .map((e) => '${e.key} ${_flatten(e.value)}')
          .join(' ');
    }
    if (value is List) {
      return value.map(_flatten).join(' ');
    }
    return value.toString();
  }

  static List<Map<String, dynamic>> _parseSteps(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return [];

    final frameTexts = trimmed.startsWith('{')
        ? TclParser.splitList(trimmed)
        : [trimmed];

    return frameTexts.map((frame) {
      final parsed = _parseFrame(frame);
      if (parsed == null) {
        throw const MalformedProfileFrameException();
      }
      return parsed;
    }).toList();
  }

  static Map<String, dynamic>? _parseFrame(String frame) {
    final tokens = TclParser.splitList(frame.trim());
    if (tokens.length < 2 || tokens.length.isOdd) return null;

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
