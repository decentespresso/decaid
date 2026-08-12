import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/shot_record.dart';

/// A bundled recording plus the profile title it was recorded with (null for
/// the generic fallback shots). Addressable by [id] for deterministic
/// selection via the debug API.
class SimulatedShot {
  const SimulatedShot(this.record, this.profileTitle);

  final ShotRecord record;
  final String? profileTitle;

  String get id => record.id;
}

/// Bundled corpus of real recorded shots the replay simulator plays back.
///
/// Two groups, both loaded from `assets/simulations/`:
///   - a generic fallback pool (de1app sample shots), and
///   - profile-matched shots pulled from visualizer.coffee, keyed by the
///     bundled profile title they were made with.
///
/// [forProfileTitle] returns the shot recorded with a given profile when one
/// was found; [pickRandom] returns a generic fallback. [pickForProfile]
/// combines them: the profile match when possible, otherwise a random shot.
class SimulatedShotLibrary {
  SimulatedShotLibrary({
    AssetBundle? bundle,
    this.manifestPath = 'assets/simulations/manifest.json',
  }) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  final String manifestPath;
  final _log = Logger('SimulatedShotLibrary');

  final List<ShotRecord> _fallback = [];
  final Map<String, ShotRecord> _byProfile = {};
  final List<SimulatedShot> _catalog = [];
  bool _loaded = false;

  bool get isLoaded => _loaded;
  bool get isEmpty => _fallback.isEmpty && _byProfile.isEmpty;
  int get fallbackCount => _fallback.length;
  int get profileCount => _byProfile.length;

  /// All bundled recordings, addressable by their stable [SimulatedShot.id].
  List<SimulatedShot> get catalog => List.unmodifiable(_catalog);

  /// The recording with the given stable id, or null.
  ShotRecord? byId(String id) {
    for (final entry in _catalog) {
      if (entry.id == id) return entry.record;
    }
    return null;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final manifest =
          jsonDecode(await _bundle.loadString(manifestPath))
              as Map<String, dynamic>;
      final dir = manifestPath.substring(0, manifestPath.lastIndexOf('/') + 1);

      for (final file in (manifest['fallback'] as List? ?? []).cast<String>()) {
        final shot = await _load('$dir$file');
        if (shot != null) {
          _fallback.add(shot);
          _catalog.add(SimulatedShot(shot, null));
        }
      }
      for (final entry in (manifest['profiles'] as List? ?? [])) {
        final map = entry as Map<String, dynamic>;
        final shot = await _load('$dir${map['file']}');
        final title = map['profileTitle'] as String?;
        if (shot != null && title != null) {
          _catalog.add(SimulatedShot(shot, title));
          for (final key in _matchKeys(title)) {
            _byProfile.putIfAbsent(key, () => shot);
          }
        }
      }
    } catch (e) {
      _log.warning('no simulation manifest at $manifestPath: $e');
    }
    _loaded = true;
  }

  /// The shot recorded with [profileTitle], or null when none was bundled.
  ShotRecord? forProfileTitle(String? profileTitle) {
    if (profileTitle == null) return null;
    for (final key in _matchKeys(profileTitle)) {
      final hit = _byProfile[key];
      if (hit != null) return hit;
    }
    return null;
  }

  /// A random generic fallback shot, or null when the corpus is empty.
  ShotRecord? pickRandom([Random? random]) {
    final pool = _fallback.isNotEmpty ? _fallback : _byProfile.values.toList();
    if (pool.isEmpty) return null;
    return pool[(random ?? Random()).nextInt(pool.length)];
  }

  /// The profile-matched shot for [profileTitle] when available, otherwise a
  /// random fallback.
  ShotRecord? pickForProfile(String? profileTitle, [Random? random]) =>
      forProfileTitle(profileTitle) ?? pickRandom(random);

  Future<ShotRecord?> _load(String assetPath) async {
    try {
      return ShotRecord.fromJson(
        jsonDecode(await _bundle.loadString(assetPath)) as Map<String, dynamic>,
      );
    } catch (e) {
      _log.warning('failed to load simulation shot $assetPath: $e');
      return null;
    }
  }

  /// Normalized match keys for a profile title: the whole title and, when the
  /// title is `prefix/name` (community shots are `author/name`, Decent titles
  /// are `category/name`), the last segment too.
  static Iterable<String> _matchKeys(String title) {
    final keys = <String>{_normalize(title)};
    final slash = title.lastIndexOf('/');
    if (slash >= 0) keys.add(_normalize(title.substring(slash + 1)));
    keys.remove('');
    return keys;
  }

  static String _normalize(String s) {
    final buf = StringBuffer();
    var prevSpace = false;
    for (final rune in s.toLowerCase().runes) {
      final c = String.fromCharCode(rune);
      if (RegExp(r'[a-z0-9]').hasMatch(c)) {
        buf.write(c);
        prevSpace = false;
      } else if (!prevSpace) {
        buf.write(' ');
        prevSpace = true;
      }
    }
    return buf.toString().trim();
  }
}
