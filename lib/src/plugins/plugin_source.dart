enum PluginSourceKind {
  githubRelease('github_release'),
  githubBranch('github_branch'),
  localZip('local_zip'),
  localFolder('local_folder');

  final String wireName;

  const PluginSourceKind(this.wireName);

  static PluginSourceKind? fromWireName(String? value) {
    for (final kind in PluginSourceKind.values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }

  bool get isManaged =>
      this == PluginSourceKind.githubRelease ||
      this == PluginSourceKind.githubBranch;
}

class PluginPendingUpdate {
  final String version;
  final String? releaseTag;
  final String? commit;
  final List<String> addedPermissions;
  final DateTime detectedAt;

  const PluginPendingUpdate({
    required this.version,
    this.releaseTag,
    this.commit,
    required this.addedPermissions,
    required this.detectedAt,
  });

  factory PluginPendingUpdate.fromJson(Map<String, dynamic> json) {
    return PluginPendingUpdate(
      version: json['version'] as String,
      releaseTag: json['releaseTag'] as String?,
      commit: json['commit'] as String?,
      addedPermissions: ((json['addedPermissions'] as List?) ?? [])
          .cast<String>(),
      detectedAt: DateTime.parse(json['detectedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'releaseTag': releaseTag,
    'commit': commit,
    'addedPermissions': addedPermissions,
    'detectedAt': detectedAt.toIso8601String(),
  };
}

class PluginSource {
  final PluginSourceKind kind;
  final String? repo;
  final String? branch;
  final String? commit;
  final String? releaseTag;
  final String? assetName;
  final bool includePrerelease;
  final DateTime installedAt;
  final DateTime? lastChecked;
  final String? lastError;
  final PluginPendingUpdate? pendingUpdate;

  const PluginSource({
    required this.kind,
    this.repo,
    this.branch,
    this.commit,
    this.releaseTag,
    this.assetName,
    this.includePrerelease = false,
    required this.installedAt,
    this.lastChecked,
    this.lastError,
    this.pendingUpdate,
  });

  factory PluginSource.fromJson(Map<String, dynamic> json) {
    final kind = PluginSourceKind.fromWireName(json['kind'] as String?);
    if (kind == null) {
      throw FormatException('Unknown plugin source kind: ${json['kind']}');
    }
    return PluginSource(
      kind: kind,
      repo: json['repo'] as String?,
      branch: json['branch'] as String?,
      commit: json['commit'] as String?,
      releaseTag: json['releaseTag'] as String?,
      assetName: json['assetName'] as String?,
      includePrerelease: json['includePrerelease'] as bool? ?? false,
      installedAt: DateTime.parse(json['installedAt'] as String),
      lastChecked: json['lastChecked'] != null
          ? DateTime.parse(json['lastChecked'] as String)
          : null,
      lastError: json['lastError'] as String?,
      pendingUpdate: json['pendingUpdate'] != null
          ? PluginPendingUpdate.fromJson(
              json['pendingUpdate'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.wireName,
    'repo': repo,
    'branch': branch,
    'commit': commit,
    'releaseTag': releaseTag,
    'assetName': assetName,
    'includePrerelease': includePrerelease,
    'installedAt': installedAt.toIso8601String(),
    'lastChecked': lastChecked?.toIso8601String(),
    'lastError': lastError,
    'pendingUpdate': pendingUpdate?.toJson(),
  };

  PluginSource copyWith({
    String? commit,
    String? releaseTag,
    DateTime? lastChecked,
    String? lastError,
    PluginPendingUpdate? pendingUpdate,
    bool clearLastError = false,
    bool clearPendingUpdate = false,
  }) {
    return PluginSource(
      kind: kind,
      repo: repo,
      branch: branch,
      commit: commit ?? this.commit,
      releaseTag: releaseTag ?? this.releaseTag,
      assetName: assetName,
      includePrerelease: includePrerelease,
      installedAt: installedAt,
      lastChecked: lastChecked ?? this.lastChecked,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      pendingUpdate: clearPendingUpdate
          ? null
          : (pendingUpdate ?? this.pendingUpdate),
    );
  }
}
