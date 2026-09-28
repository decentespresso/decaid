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

/// de1app maps these to `pourover`/`cleaning` (see `tools/ingest_profiles.py`
/// and its own `BEVERAGE_TYPE_MAP`); anything left over after that mapping
/// that still isn't one of [BeverageType]'s names is rejected rather than
/// silently defaulted to espresso by `Profile.fromJson`.
class UnsupportedBeverageTypeException implements Exception {
  final String beverageType;
  const UnsupportedBeverageTypeException(this.beverageType);

  @override
  String toString() =>
      'Beverage type $beverageType is not supported for TCL import';
}

/// `_parseFrame` rejected a frame in `advanced_shot` (too few tokens, or an
/// odd trailing key with no value). Importing the profile anyway would
/// silently drop or truncate a step, so the whole profile is rejected.
class MalformedProfileFrameException implements Exception {
  const MalformedProfileFrameException();

  @override
  String toString() => 'Malformed advanced_shot frame while importing profile';
}

class TclProfileParser {
  TclProfileParser._();

  // de1app's own `fix_profile_type` (de1plus/profile.tcl) normalizes these
  // historical aliases before deciding what a profile type means; decaid
  // only understands the resulting "settings_2c" (advanced) shape.
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

  // TclParser's braced-value heuristics can't always tell a flat text value
  // (e.g. a four-word `profile_title`) apart from an even-length key/value
  // list, and returns a Map (or, for all-numeric tokens, a List) instead of
  // a String. Text fields here are never actually structured, so flattening
  // back to the original space-joined words recovers the real value.
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

  // `advanced_shot`'s value is `{frame1} {frame2} ...`; each frame is itself
  // `key value key value ...` with `{...}`-grouped values. Both levels are
  // the same space-separated/brace-grouped shape `TclParser.splitList`
  // already tokenises, so splitting frames and splitting a frame's own
  // fields are the same call one level apart.
  //
  // When there's exactly one frame, TclParser.parse's generic value
  // collapsing already strips that frame's own wrapping braces (there's
  // nothing left to disambiguate it from a plain string), leaving just the
  // frame's flat key/value text with no leading `{`. A multi-frame value
  // keeps its per-frame braces (`{frame1} {frame2}`) because collapsing
  // isn't applied to more than one token. That leading `{` is therefore the
  // only signal for whether another round of splitting is needed.
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
