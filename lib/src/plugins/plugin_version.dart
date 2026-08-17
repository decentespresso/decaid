int comparePluginVersions(String a, String b) {
  final versionA = _PluginVersion.parse(a);
  final versionB = _PluginVersion.parse(b);
  return versionA.compareTo(versionB);
}

class _PluginVersion {
  final List<int> core;
  final List<String> prerelease;

  const _PluginVersion(this.core, this.prerelease);

  factory _PluginVersion.parse(String version) {
    final withoutBuild = version.split('+').first;
    final dashIndex = withoutBuild.indexOf('-');
    final core = dashIndex == -1
        ? withoutBuild
        : withoutBuild.substring(0, dashIndex);
    final prerelease = dashIndex == -1
        ? const <String>[]
        : withoutBuild
              .substring(dashIndex + 1)
              .split('.')
              .where((part) => part.isNotEmpty)
              .toList();
    return _PluginVersion(
      core.split('.').map((part) => int.tryParse(part) ?? 0).toList(),
      prerelease,
    );
  }

  int compareTo(_PluginVersion other) {
    final length = core.length > other.core.length
        ? core.length
        : other.core.length;
    for (var i = 0; i < length; i++) {
      final mine = i < core.length ? core[i] : 0;
      final theirs = i < other.core.length ? other.core[i] : 0;
      if (mine != theirs) return mine.compareTo(theirs);
    }

    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;

    final identifiers = prerelease.length > other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var i = 0; i < identifiers; i++) {
      if (i >= prerelease.length) return -1;
      if (i >= other.prerelease.length) return 1;
      final result = _compareIdentifiers(prerelease[i], other.prerelease[i]);
      if (result != 0) return result;
    }
    return 0;
  }

  static int _compareIdentifiers(String a, String b) {
    final numericA = int.tryParse(a);
    final numericB = int.tryParse(b);
    if (numericA != null && numericB != null) {
      return numericA.compareTo(numericB);
    }
    if (numericA != null) return -1;
    if (numericB != null) return 1;
    return a.compareTo(b);
  }
}
