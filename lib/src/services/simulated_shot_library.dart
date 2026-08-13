import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/shot_record.dart';

/// [originalDurationSeconds] is the recording's real endpoint, before the
/// stop-at-weight tail extension.
class SimulatedShot {
  const SimulatedShot(
    this.record,
    this.profileTitle,
    this.originalDurationSeconds,
  );

  final ShotRecord record;
  final String? profileTitle;
  final double originalDurationSeconds;

  String get id => record.id;
}

class SimulatedShotLibrary {
  SimulatedShotLibrary({
    AssetBundle? bundle,
    this.manifestPath = 'assets/simulations/manifest.json',
  }) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  final String manifestPath;
  final _log = Logger('SimulatedShotLibrary');

  final List<ShotRecord> _fallback = [];
  final Map<String, ShotRecord> _byCanonical = {};
  final Map<String, Set<ShotRecord>> _aliasCandidates = {};
  final Map<String, ShotRecord> _byAlias = {};
  final List<SimulatedShot> _catalog = [];
  bool _loaded = false;

  bool get isLoaded => _loaded;
  bool get isEmpty => _fallback.isEmpty && _byCanonical.isEmpty;
  int get fallbackCount => _fallback.length;
  int get profileCount => _byCanonical.length;

  List<SimulatedShot> get catalog => List.unmodifiable(_catalog);

  ShotRecord? byId(String id) {
    for (final entry in _catalog) {
      if (entry.id == id) return entry.record;
    }
    return null;
  }

  double? originalDurationOf(String id) {
    for (final entry in _catalog) {
      if (entry.id == id) return entry.originalDurationSeconds;
    }
    return null;
  }

  static double _duration(Map<String, dynamic> entry) =>
      (entry['originalDurationSeconds'] as num?)?.toDouble() ?? 0.0;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final manifest =
          jsonDecode(await _bundle.loadString(manifestPath))
              as Map<String, dynamic>;
      final dir = manifestPath.substring(0, manifestPath.lastIndexOf('/') + 1);

      for (final entry in (manifest['fallback'] as List? ?? [])) {
        final map = entry as Map<String, dynamic>;
        final shot = await _load('$dir${map['file']}');
        if (shot != null) {
          _fallback.add(shot);
          _catalog.add(SimulatedShot(shot, null, _duration(map)));
        }
      }
      for (final entry in (manifest['profiles'] as List? ?? [])) {
        final map = entry as Map<String, dynamic>;
        final shot = await _load('$dir${map['file']}');
        final title = map['profileTitle'] as String?;
        if (shot != null && title != null) {
          _catalog.add(SimulatedShot(shot, title, _duration(map)));
          _byCanonical.putIfAbsent(_normalize(title), () => shot);
          final alias = _lastSegment(title);
          if (alias != null) {
            _aliasCandidates.putIfAbsent(alias, () => {}).add(shot);
          }
        }
      }
      // Alias usable only when unambiguous and not shadowing a canonical title.
      _aliasCandidates.forEach((alias, shots) {
        if (shots.length == 1 && !_byCanonical.containsKey(alias)) {
          _byAlias[alias] = shots.single;
        }
      });
    } catch (e) {
      _log.warning('no simulation manifest at $manifestPath: $e');
    }
    _loaded = true;
  }

  ShotRecord? forProfileTitle(String? profileTitle) {
    if (profileTitle == null) return null;
    for (final key in _matchKeys(profileTitle)) {
      final hit = _byCanonical[key];
      if (hit != null) return hit;
    }
    for (final key in _matchKeys(profileTitle)) {
      final hit = _byAlias[key];
      if (hit != null) return hit;
    }
    return null;
  }

  ShotRecord? pickRandom([Random? random]) {
    final pool = _fallback.isNotEmpty
        ? _fallback
        : _byCanonical.values.toList();
    if (pool.isEmpty) return null;
    return pool[(random ?? Random()).nextInt(pool.length)];
  }

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

  static List<String> _matchKeys(String title) {
    final full = _normalize(title);
    final alias = _lastSegment(title);
    return [
      if (full.isNotEmpty) full,
      if (alias != null && alias != full) alias,
    ];
  }

  static String? _lastSegment(String title) {
    final slash = title.lastIndexOf('/');
    if (slash < 0) return null;
    final seg = _normalize(title.substring(slash + 1));
    return seg.isEmpty ? null : seg;
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
