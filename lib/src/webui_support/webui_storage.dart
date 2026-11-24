import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;
import 'package:reaprime/src/util/remote_error.dart';
import 'package:reaprime/src/util/remote_update_exception.dart';
import 'package:reaprime/src/util/remote_update_report.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/services/github_request.dart';
import 'package:reaprime/src/services/release_request.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';
import 'package:reaprime/src/util/safe_path.dart';
import 'package:reaprime/src/webui_support/webui_zip_support.dart';

class WebUIReaMetadata {
  final String skinId;
  final String? sourceUrl;
  final String? lastModified;
  final String? etag;
  final String? commitHash;
  final String? releaseAssetName;
  final bool? includePrerelease;
  final DateTime installedAt;
  final DateTime? lastChecked;

  WebUIReaMetadata({
    required this.skinId,
    this.sourceUrl,
    this.lastModified,
    this.etag,
    this.commitHash,
    this.releaseAssetName,
    this.includePrerelease,
    required this.installedAt,
    this.lastChecked,
  });

  factory WebUIReaMetadata.fromJson(Map<String, dynamic> json) {
    return WebUIReaMetadata(
      skinId: json['skinId'] as String,
      sourceUrl: json['sourceUrl'] as String?,
      lastModified: json['lastModified'] as String?,
      etag: json['etag'] as String?,
      commitHash: json['commitHash'] as String?,
      releaseAssetName: json['releaseAssetName'] as String?,
      includePrerelease: json['includePrerelease'] as bool?,
      installedAt: DateTime.parse(json['installedAt'] as String),
      lastChecked: json['lastChecked'] != null
          ? DateTime.parse(json['lastChecked'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'skinId': skinId,
      'sourceUrl': sourceUrl,
      'lastModified': lastModified,
      'etag': etag,
      'commitHash': commitHash,
      'releaseAssetName': releaseAssetName,
      'includePrerelease': includePrerelease,
      'installedAt': installedAt.toIso8601String(),
      'lastChecked': lastChecked?.toIso8601String(),
    };
  }

  WebUIReaMetadata copyWith({
    String? sourceUrl,
    String? lastModified,
    String? etag,
    String? commitHash,
    String? releaseAssetName,
    bool? includePrerelease,
    DateTime? installedAt,
    DateTime? lastChecked,
  }) {
    return WebUIReaMetadata(
      skinId: skinId,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      lastModified: lastModified ?? this.lastModified,
      etag: etag ?? this.etag,
      commitHash: commitHash ?? this.commitHash,
      releaseAssetName: releaseAssetName ?? this.releaseAssetName,
      includePrerelease: includePrerelease ?? this.includePrerelease,
      installedAt: installedAt ?? this.installedAt,
      lastChecked: lastChecked ?? this.lastChecked,
    );
  }
}

class WebUISkin {
  final String id;
  final String name;
  final String path;
  final String? description;
  final String? version;
  final bool isBundled;
  final WebUIReaMetadata? reaMetadata;

  WebUISkin({
    required this.id,
    required this.name,
    required this.path,
    this.description,
    this.version,
    this.isBundled = false,
    this.reaMetadata,
  });

  factory WebUISkin.fromJson(Map<String, dynamic> json) {
    return WebUISkin(
      id: json['id'] as String,
      name: json['name'] as String,
      path: json['path'] as String,
      description: json['description'] as String?,
      version: json['version'] as String?,
      isBundled: json['isBundled'] as bool? ?? false,
      reaMetadata: json['reaMetadata'] != null
          ? WebUIReaMetadata.fromJson(
              json['reaMetadata'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'description': description,
      'version': version,
      'isBundled': isBundled,
      'reaMetadata': reaMetadata?.toJson(),
    };
  }
}

class WebUIStorage {
  final _log = Logger('WebUIStorage');
  static const _stagingDirName = '.webui-install-staging';
  final SettingsController _settingsController;
  final Directory? _webUIDirOverride;

  late Directory _webUIDir;
  final Map<String, WebUISkin> _installedSkins = {};
  final Map<String, List<String>> _skinPaths = {};
  final Map<String, WebUIReaMetadata> _skinMetadata = {};
  bool _initialized = false;
  final ValueNotifier<Future<void>?> _updateCheck = ValueNotifier(null);
  Future<RemoteUpdateReport>? _updateCheckReport;
  Future<List<RemoteUpdateItemResult>>? _remoteDownload;
  Future<void>? _downloadRemoteSkinsCheck;

  final GithubRateLimit _rateLimit;
  final GithubCredentialProvider? credentials;

  WebUIStorage(
    this._settingsController, {
    Directory? webUIDir,
    GithubRateLimit? rateLimit,
    this.credentials,
  }) : _webUIDirOverride = webUIDir,
       _rateLimit = rateLimit ?? GithubRateLimit();

  Future<http.Response> _getGitHubRelease(String apiUrl) =>
      githubGet(apiUrl, rateLimit: _rateLimit, credentials: credentials);

  ValueListenable<Future<void>?> get updateCheck => _updateCheck;

  @visibleForTesting
  static bool get diagnosticsSkinEnabled => bool.fromEnvironment('diagnostics');

  @visibleForTesting
  void debugInitWithWebUIDir(Directory dir) {
    _webUIDir = dir;
    if (!_webUIDir.existsSync()) {
      _webUIDir.createSync(recursive: true);
    }
    _initialized = true;
  }

  static List<String> get _bundledAssetPaths =>
      diagnosticsSkinEnabled ? ['assets/ble-reconnect-diagnostics/'] : [];

  static List<Map<String, dynamic>>? _remoteWebUISourcesCache;

  Future<List<Map<String, dynamic>>> _getRemoteWebUISources() async {
    if (_remoteWebUISourcesCache != null) return _remoteWebUISourcesCache!;
    try {
      final configString = await rootBundle.loadString('skin_sources.json');
      _remoteWebUISourcesCache = (jsonDecode(configString) as List)
          .cast<Map<String, dynamic>>();
    } catch (e) {
      _log.warning('Failed to load skin_sources.json', e);
      _remoteWebUISourcesCache = [];
    }
    return _remoteWebUISourcesCache!;
  }

  final Set<String> _remoteBundledSkinIds = {};

  Future<void> initialize({bool downloadRemote = true}) async {
    if (_initialized) {
      _log.fine('WebUIStorage already initialized');
      return;
    }

    _webUIDir = _webUIDirOverride ?? Directory(await AppDirectories.webUi);

    if (!_webUIDir.existsSync()) {
      _webUIDir.createSync(recursive: true);
      _log.info('Created web-ui directory: ${_webUIDir.path}');
    }

    await _loadRemoteBundledSkinIds();

    await _loadSkinMetadata();

    await _copyBundledSkins();

    if (downloadRemote) {
      try {
        await downloadRemoteSkins();
      } on RemoteUpdateException catch (e, st) {
        _log.warning('Remote skins unavailable during initialization', e, st);
      }
    }

    await _scanInstalledSkins();

    _initialized = true;
    _log.info('WebUIStorage initialized with ${_installedSkins.length} skins');
  }

  List<WebUISkin> get installedSkins => _installedSkins.values.toList();

  WebUISkin? getSkin(String id) => _installedSkins[id];

  Iterable<String> legacySkinPaths(String path) {
    final skin = _installedSkins.values
        .where((skin) => skin.path == path)
        .firstOrNull;
    if (skin == null) return const [];
    return (_skinPaths[skin.id] ?? const <String>[]).reversed.where(
      (candidate) => candidate != path,
    );
  }

  WebUISkin? get defaultSkin {
    final preferredSkinId = _settingsController.defaultSkinId;
    _log.info(
      "selecting preferred skin: $preferredSkinId, in: $_installedSkins",
    );
    if (_installedSkins.containsKey(preferredSkinId)) {
      return _installedSkins[preferredSkinId];
    }

    if (preferredSkinId != 'streamline.js') {
      _log.warning(
        'Preferred skin "$preferredSkinId" not found, falling back to default',
      );
    }

    final streamlineSkin = _installedSkins['streamline.js'];
    if (streamlineSkin != null) {
      return streamlineSkin;
    }

    final bundledSkin = _installedSkins.values
        .where((skin) => skin.isBundled)
        .firstOrNull;

    if (bundledSkin != null) {
      return bundledSkin;
    }

    return _installedSkins.values.firstOrNull;
  }

  Future<void> setDefaultSkin(String skinId) async {
    if (!_installedSkins.containsKey(skinId)) {
      throw Exception('Skin not found: $skinId');
    }

    await _settingsController.setDefaultSkinId(skinId);
    _log.info('Set default skin to: $skinId');
  }

  Future<String> installFromPath(
    String sourcePath, {
    bool overwriteIfExists = true,
  }) async {
    final source = File(sourcePath);
    final sourceDir = Directory(sourcePath);

    String skinId;
    if (source.existsSync() && sourcePath.endsWith('.zip')) {
      skinId = await _installFromZip(
        sourcePath,
        overwriteIfExists: overwriteIfExists,
      );
    } else if (sourceDir.existsSync()) {
      skinId = await _installFromDirectory(
        sourceDir,
        overwriteIfExists: overwriteIfExists,
      );
    } else {
      throw Exception('Source does not exist: $sourcePath');
    }

    await _scanInstalledSkins();
    return skinId;
  }

  Future<void> installFromUrl(
    String url, {
    String? sourceIdentifier,
    String? releaseAssetName,
    bool? includePrerelease,
  }) => _installFromUrl(
    url,
    sourceIdentifier: sourceIdentifier,
    releaseAssetName: releaseAssetName,
    includePrerelease: includePrerelease,
  );

  Future<void> _installFromUrl(
    String url, {
    String? sourceIdentifier,
    String? releaseAssetName,
    bool? includePrerelease,
    bool isReleaseDownload = false,
  }) async {
    _log.info('Downloading WebUI from URL: $url');

    try {
      final response = isReleaseDownload
          ? await releaseGet(url)
          : await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw remoteHttpError(response.statusCode);
      }
      final etag = response.headers['etag'];
      final lastModified = response.headers['last-modified'];

      final tempDir = await Directory(await AppDirectories.temp)
          .createTemp('webui_install');
      final tempFile = File('${tempDir.path}/skin.zip');
      await tempFile.writeAsBytes(response.bodyBytes);

      String installedSkinId;
      try {
        installedSkinId = await _installFromZip(tempFile.path);
      } finally {
        await tempDir.delete(recursive: true);
      }

      _skinMetadata[installedSkinId] = WebUIReaMetadata(
        skinId: installedSkinId,
        sourceUrl: sourceIdentifier ?? url,
        releaseAssetName: releaseAssetName,
        includePrerelease: includePrerelease,
        etag: etag,
        lastModified: lastModified,
        installedAt: DateTime.now(),
        lastChecked: DateTime.now(),
      );
      await _saveSkinMetadata();

      await _scanInstalledSkins();

      _log.info('Successfully installed WebUI from URL: $url');
    } catch (e) {
      _log.severe('Failed to install WebUI from URL: $url', e);
      rethrow;
    }
  }

  Future<void> installFromGitHub(String repo, {String branch = 'main'}) async {
    final parts = repo.split('/');
    if (parts.length < 2) {
      throw const UserFacingFormatException(
        'Invalid GitHub repo format. Use: owner/repo',
      );
    }

    final owner = parts[0];
    final repoName = parts[1];
    final branchName = parts.length > 2 ? parts[2] : branch;

    final url =
        'https://github.com/$owner/$repoName/archive/refs/heads/$branchName.zip';
    final sourceIdentifier = 'github_branch:$owner/$repoName@$branchName';

    await _installFromUrlAsRemoteBundled(
      url,
      markAsRemoteBundled: false,
      sourceIdentifier: sourceIdentifier,
    );
  }

  Future<void> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    final parts = repo.split('/');
    if (parts.length != 2) {
      throw const UserFacingFormatException(
        'Invalid GitHub repo format. Use: owner/repo',
      );
    }

    _log.info('Installing WebUI from GitHub release: $repo');

    try {
      final apiUrl = includePrerelease
          ? 'https://api.github.com/repos/$repo/releases'
          : 'https://api.github.com/repos/$repo/releases/latest';

      final releaseResponse = await _getGitHubRelease(apiUrl);

      final dynamic releaseData = includePrerelease
          ? (jsonDecode(releaseResponse.body) as List).first
          : jsonDecode(releaseResponse.body);

      final releaseTag = releaseData['tag_name'] as String;
      final releaseName = releaseData['name'] as String;
      final assets = releaseData['assets'] as List;

      _log.info('Found release: $releaseName ($releaseTag)');

      dynamic targetAsset;
      if (assetName != null) {
        targetAsset = assets.firstWhere(
          (asset) => asset['name'] == assetName,
          orElse: () =>
              throw UserFacingFormatException('Asset not found: $assetName'),
        );
      } else {
        targetAsset = assets.firstWhere(
          (asset) => (asset['name'] as String).endsWith('.zip'),
          orElse: () => throw const UserFacingFormatException(
            'No .zip asset found in release',
          ),
        );
      }

      final downloadUrl = targetAsset['browser_download_url'] as String;

      _log.info('Downloading asset: ${targetAsset['name']}');

      await _installFromUrl(
        downloadUrl,
        sourceIdentifier: 'github_release:$repo@$releaseTag',
        releaseAssetName: assetName,
        includePrerelease: includePrerelease,
        isReleaseDownload: true,
      );

      _log.info(
        'Successfully installed WebUI from GitHub release: $releaseTag',
      );
    } catch (e) {
      _log.severe('Failed to install WebUI from GitHub release: $repo', e);
      rethrow;
    }
  }

  Future<void> downloadRemoteSkins() =>
      _downloadRemoteSkinsCheck ??= _downloadRemoteSkins().whenComplete(
        () => _downloadRemoteSkinsCheck = null,
      );

  Future<void> _downloadRemoteSkins() async {
    final results = await checkRemoteBundledSkins();
    final failures = [
      for (final result in results)
        if (result.isFailure)
          (item: result.item, error: result.error as Object),
    ];
    if (failures.isNotEmpty) {
      throw RemoteUpdateException(
        attemptedCount: results.length,
        failures: failures,
      );
    }
  }

  Future<List<RemoteUpdateItemResult>> checkRemoteBundledSkins() =>
      _remoteDownload ??= _checkRemoteBundledSkins().whenComplete(
        () => _remoteDownload = null,
      );

  Future<List<RemoteUpdateItemResult>> _checkRemoteBundledSkins() async {
    final sources = await _getRemoteWebUISources();
    final results = <RemoteUpdateItemResult>[];
    for (final sourceConfig in sources) {
      final item = '${sourceConfig['repo'] ?? sourceConfig['url']}';
      try {
        final type = sourceConfig['type'] as String;

        switch (type) {
          case 'github_release':
            final repo = sourceConfig['repo'] as String;
            final asset = sourceConfig['asset'] as String?;
            final prerelease = sourceConfig['prerelease'] as bool? ?? false;

            _log.info(
              'Downloading remote bundled skin from GitHub release: $repo',
            );
            results.add(
              RemoteUpdateItemResult(
                item: item,
                status: await _installFromGitHubRelease(
                  repo,
                  asset,
                  prerelease,
                ),
              ),
            );
            break;

          case 'github_branch':
            final repo = sourceConfig['repo'] as String;
            final branch = sourceConfig['branch'] as String? ?? 'main';
            final url =
                'https://github.com/$repo/archive/refs/heads/$branch.zip';

            _log.info(
              'Downloading remote bundled skin from GitHub branch: $repo/$branch',
            );
            results.add(
              RemoteUpdateItemResult(
                item: item,
                status: await _installFromUrlAsRemoteBundled(url),
              ),
            );
            break;

          case 'url':
            final url = sourceConfig['url'] as String;

            _log.info('Downloading remote bundled skin from URL: $url');
            results.add(
              RemoteUpdateItemResult(
                item: item,
                status: await _installFromUrlAsRemoteBundled(url),
              ),
            );
            break;

          default:
            _log.warning('Unknown remote source type: $type');
            results.add(
              RemoteUpdateItemResult(
                item: sourceConfig['repo'] ?? sourceConfig['url'] ?? type,
                status: RemoteUpdateStatus.failed,
                error: FormatException('Unknown remote source type: $type'),
              ),
            );
        }
      } catch (e, st) {
        results.add(
          RemoteUpdateItemResult(
            item: item,
            status: RemoteUpdateStatus.failed,
            error: e,
          ),
        );
        _log.warning(
          'Failed to download remote skin from $sourceConfig',
          e,
          st,
        );
      }
    }
    return results;
  }

  Future<void> downloadRemoteSkinsAndRescan() async {
    try {
      await downloadRemoteSkins();
    } finally {
      await _scanInstalledSkins();
    }
  }

  Future<void> updateAllSkins() async {
    final report = await checkForSkinUpdates();
    if (report.hasFailures) {
      throw RemoteUpdateException(
        attemptedCount: report.results.length,
        failures: report.failures,
      );
    }
  }

  Future<RemoteUpdateReport> checkForSkinUpdates() {
    final existing = _updateCheckReport;
    if (existing != null) return existing;
    final report = _runSkinUpdates().whenComplete(() {
      _updateCheckReport = null;
      _updateCheck.value = null;
    });
    _updateCheckReport = report;
    _updateCheck.value = report.then<void>((_) {}).catchError((Object _) {});
    return report;
  }

  Future<RemoteUpdateReport> _runSkinUpdates() async {
    _log.info('Starting update check for all skins');
    final results = <RemoteUpdateItemResult>[
      ...await checkRemoteBundledSkins(),
      ...await _checkUserSkins(),
    ];
    await _scanInstalledSkins();
    _log.info('Finished update check for all skins');
    return RemoteUpdateReport(results);
  }

  Future<List<RemoteUpdateItemResult>> _checkUserSkins() async {
    final results = <RemoteUpdateItemResult>[];
    final userSkins = _skinMetadata.entries
        .where(
          (entry) =>
              entry.value.sourceUrl != null &&
              !_remoteBundledSkinIds.contains(entry.key),
        )
        .toList();

    for (final entry in userSkins) {
      final skinId = entry.key;
      final sourceUrl = entry.value.sourceUrl!;
      if (!sourceUrl.startsWith('github_release:') &&
          !sourceUrl.startsWith('github_branch:') &&
          !sourceUrl.startsWith('http')) {
        _log.fine(
          'Skipping skin "$skinId" with unsupported source type: $sourceUrl',
        );
        continue;
      }

      try {
        if (sourceUrl.startsWith('github_release:')) {
          final withoutPrefix = sourceUrl.substring('github_release:'.length);
          final atIndex = withoutPrefix.indexOf('@');
          final repo = atIndex >= 0
              ? withoutPrefix.substring(0, atIndex)
              : withoutPrefix;

          _log.info(
            'Updating user-installed skin "$skinId" from GitHub release: $repo',
          );
          results.add(
            RemoteUpdateItemResult(
              item: skinId,
              status: await _installFromGitHubRelease(
                repo,
                entry.value.releaseAssetName,
                entry.value.includePrerelease ?? false,
                markAsRemoteBundled: false,
                expectedSkinId: skinId,
              ),
            ),
          );
        } else if (sourceUrl.startsWith('github_branch:')) {
          final withoutPrefix = sourceUrl.substring('github_branch:'.length);
          final atIndex = withoutPrefix.indexOf('@');
          final repo = atIndex >= 0
              ? withoutPrefix.substring(0, atIndex)
              : withoutPrefix;
          final branch = atIndex >= 0
              ? withoutPrefix.substring(atIndex + 1)
              : 'main';

          _log.info(
            'Updating user-installed skin "$skinId" from GitHub branch: '
            '$repo@$branch',
          );
          final url = 'https://github.com/$repo/archive/refs/heads/$branch.zip';
          results.add(
            RemoteUpdateItemResult(
              item: skinId,
              status: await _installFromUrlAsRemoteBundled(
                url,
                markAsRemoteBundled: false,
                sourceIdentifier: 'github_branch:$repo@$branch',
                expectedSkinId: skinId,
              ),
            ),
          );
        } else {
          _log.info(
            'Updating user-installed skin "$skinId" from URL: $sourceUrl',
          );
          results.add(
            RemoteUpdateItemResult(
              item: skinId,
              status: await _installFromUrlAsRemoteBundled(
                sourceUrl,
                markAsRemoteBundled: false,
                expectedSkinId: skinId,
              ),
            ),
          );
        }
      } catch (e, st) {
        results.add(
          RemoteUpdateItemResult(
            item: skinId,
            status: RemoteUpdateStatus.failed,
            error: e,
          ),
        );
        _log.warning('Failed to update skin "$skinId" from $sourceUrl', e, st);
      }
    }

    return results;
  }

  Future<RemoteUpdateStatus> _installFromGitHubRelease(
    String repo,
    String? assetName,
    bool includePrerelease, {
    bool markAsRemoteBundled = true,
    String? expectedSkinId,
  }) async {
    try {
      final apiUrl = includePrerelease
          ? 'https://api.github.com/repos/$repo/releases'
          : 'https://api.github.com/repos/$repo/releases/latest';

      _log.fine('Fetching GitHub release info from: $apiUrl');

      final releaseResponse = await _getGitHubRelease(apiUrl);

      final dynamic releaseData = includePrerelease
          ? (jsonDecode(releaseResponse.body) as List).first
          : jsonDecode(releaseResponse.body);

      final releaseTag = releaseData['tag_name'] as String;
      final releaseName = releaseData['name'] as String;
      final publishedAt = releaseData['published_at'] as String;
      final assets = releaseData['assets'] as List;

      _log.info(
        'Found release: $releaseName ($releaseTag) published at $publishedAt',
      );

      dynamic targetAsset;
      if (assetName != null) {
        targetAsset = assets.firstWhere(
          (asset) => asset['name'] == assetName,
          orElse: () =>
              throw UserFacingFormatException('Asset not found: $assetName'),
        );
      } else {
        targetAsset = assets.firstWhere(
          (asset) => (asset['name'] as String).endsWith('.zip'),
          orElse: () => throw const UserFacingFormatException(
            'No .zip asset found in release',
          ),
        );
      }

      final downloadUrl = targetAsset['browser_download_url'] as String;
      final assetSize = targetAsset['size'] as int;

      _log.info(
        'Downloading asset: ${targetAsset['name']} (${(assetSize / 1024 / 1024).toStringAsFixed(2)} MB)',
      );

      final sourceIdentifier = 'github_release:$repo@$releaseTag';
      final existingMetadata = expectedSkinId != null
          ? _skinMetadata[expectedSkinId]
          : _skinMetadata.values
                .where((meta) => _tracksReleaseRepo(meta, repo))
                .firstOrNull;
      final boundSkinId = expectedSkinId ?? existingMetadata?.skinId;

      if (existingMetadata != null &&
          existingMetadata.sourceUrl == sourceIdentifier) {
        _log.info('Release $releaseTag already installed, skipping download');

        _skinMetadata[existingMetadata.skinId] = existingMetadata.copyWith(
          lastChecked: DateTime.now(),
        );
        await _saveSkinMetadata();
        return RemoteUpdateStatus.alreadyCurrent;
      }

      final assetResponse = await releaseGet(downloadUrl);
      if (assetResponse.statusCode != 200) {
        throw remoteHttpError(assetResponse.statusCode);
      }

      final tempDir = await Directory(await AppDirectories.temp)
          .createTemp('webui_install');
      final tempFile = File('${tempDir.path}/skin.zip');
      await tempFile.writeAsBytes(assetResponse.bodyBytes);

      String installedSkinId;
      try {
        installedSkinId = await _installFromZip(
          tempFile.path,
          expectedSkinId: boundSkinId,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }

      if (markAsRemoteBundled) {
        _remoteBundledSkinIds.add(installedSkinId);
        await _saveRemoteBundledSkinIds();
      }

      _skinMetadata[installedSkinId] = WebUIReaMetadata(
        skinId: installedSkinId,
        sourceUrl: sourceIdentifier,
        commitHash: releaseTag,
        releaseAssetName: assetName,
        includePrerelease: includePrerelease,
        etag: null,
        lastModified: publishedAt,
        installedAt: DateTime.now(),
        lastChecked: DateTime.now(),
      );
      await _saveSkinMetadata();

      _log.info(
        'Successfully installed skin from GitHub release: $installedSkinId ($releaseTag)',
      );

      await _scanInstalledSkins();
      return RemoteUpdateStatus.updated;
    } catch (e, st) {
      _log.severe('Failed to install from GitHub release: $repo', e, st);
      rethrow;
    }
  }

  bool _tracksReleaseRepo(WebUIReaMetadata metadata, String repo) =>
      metadata.sourceUrl?.startsWith('github_release:$repo@') ?? false;

  Future<RemoteUpdateStatus> _installFromUrlAsRemoteBundled(
    String url, {
    bool markAsRemoteBundled = true,
    String? sourceIdentifier,
    String? expectedSkinId,
  }) async {
    try {
      final headResponse = await http.head(Uri.parse(url));
      final etag = headResponse.headers['etag'];
      final lastModified = headResponse.headers['last-modified'];
      final trackedSource = sourceIdentifier ?? url;

      final existingMetadata = _skinMetadata.values.firstWhere(
        (meta) => meta.sourceUrl == trackedSource,
        orElse: () => WebUIReaMetadata(skinId: '', installedAt: DateTime.now()),
      );
      final boundSkinId =
          expectedSkinId ??
          (existingMetadata.skinId.isNotEmpty ? existingMetadata.skinId : null);

      bool needsUpdate = true;
      if (existingMetadata.skinId.isNotEmpty) {
        if (etag != null && etag == existingMetadata.etag) {
          needsUpdate = false;
          _log.info('Skin from $url is up to date (ETag match)');
        } else if (lastModified != null &&
            lastModified == existingMetadata.lastModified) {
          needsUpdate = false;
          _log.info('Skin from $url is up to date (Last-Modified match)');
        }
      }

      if (!needsUpdate) {
        _skinMetadata[existingMetadata.skinId] = existingMetadata.copyWith(
          lastChecked: DateTime.now(),
        );
        await _saveSkinMetadata();
        return RemoteUpdateStatus.alreadyCurrent;
      }

      _log.info('Downloading WebUI from URL: $url');

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw remoteHttpError(response.statusCode);
      }

      final tempDir = await Directory(await AppDirectories.temp)
          .createTemp('webui_install');
      final tempFile = File('${tempDir.path}/skin.zip');
      await tempFile.writeAsBytes(response.bodyBytes);

      String? commitHash;

      if (url.contains('github.com')) {
        commitHash = _extractGitHubCommitHash(url);
      }

      String installedSkinId;
      try {
        installedSkinId = await _installFromZip(
          tempFile.path,
          expectedSkinId: boundSkinId,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }

      if (markAsRemoteBundled) {
        _remoteBundledSkinIds.add(installedSkinId);
        await _saveRemoteBundledSkinIds();
      }

      _skinMetadata[installedSkinId] = WebUIReaMetadata(
        skinId: installedSkinId,
        sourceUrl: trackedSource,
        etag: etag,
        lastModified: lastModified,
        commitHash: commitHash,
        installedAt: DateTime.now(),
        lastChecked: DateTime.now(),
      );
      await _saveSkinMetadata();

      _log.info('Installed/updated remote bundled skin: $installedSkinId');

      await _scanInstalledSkins();

      _log.info('Successfully installed remote bundled WebUI from URL: $url');
      return RemoteUpdateStatus.updated;
    } catch (e) {
      _log.severe('Failed to install WebUI from URL: $url', e);
      rethrow;
    }
  }

  String? _extractGitHubCommitHash(String url) {
    try {
      final match = RegExp(
        r'github\.com/([^/]+)/([^/]+)/archive/refs/heads/([^\.]+)\.zip',
      ).firstMatch(url);

      if (match != null) {
        final branch = match.group(3);
        return 'branch:$branch';
      }

      return null;
    } catch (e) {
      _log.warning('Failed to extract GitHub commit hash from URL: $url', e);
      return null;
    }
  }

  Future<void> removeSkin(String skinId) async {
    if (!_installedSkins.containsKey(skinId)) {
      throw Exception('Skin not found: $skinId');
    }

    final skin = _installedSkins[skinId]!;

    if (skin.isBundled) {
      throw Exception('Cannot remove bundled skin: $skinId');
    }

    final skinDir = Directory(skin.path);
    if (skinDir.existsSync()) {
      await skinDir.delete(recursive: true);
      _log.info('Removed skin: $skinId');
    }

    _installedSkins.remove(skinId);

    if (_skinMetadata.containsKey(skinId)) {
      _skinMetadata.remove(skinId);
      await _saveSkinMetadata();
    }
  }

  bool isSkinInstalled(String skinId) {
    return _installedSkins.containsKey(skinId);
  }

  String getSkinPath(String skinId) {
    final skin = _installedSkins[skinId];
    if (skin == null) {
      throw Exception('Skin not found: $skinId');
    }
    return skin.path;
  }

  Future<void> _loadRemoteBundledSkinIds() async {
    try {
      final registryFile = File(
        '${_webUIDir.path}/.remote_bundled_registry.json',
      );
      if (registryFile.existsSync()) {
        final contents = await registryFile.readAsString();
        final List<dynamic> skinIds = jsonDecode(contents);
        _remoteBundledSkinIds.addAll(skinIds.cast<String>());
        _log.fine(
          'Loaded ${_remoteBundledSkinIds.length} remote bundled skin IDs',
        );
      }
    } catch (e) {
      _log.warning('Failed to load remote bundled skin IDs registry', e);
    }
  }

  Future<void> _saveRemoteBundledSkinIds() async {
    try {
      final registryFile = File(
        '${_webUIDir.path}/.remote_bundled_registry.json',
      );
      await registryFile.writeAsString(
        jsonEncode(_remoteBundledSkinIds.toList()),
      );
      _log.fine(
        'Saved ${_remoteBundledSkinIds.length} remote bundled skin IDs',
      );
    } catch (e) {
      _log.warning('Failed to save remote bundled skin IDs registry', e);
    }
  }

  Future<void> _loadSkinMetadata() async {
    try {
      final metadataFile = File('${_webUIDir.path}/.rea_metadata.json');
      if (metadataFile.existsSync()) {
        final contents = await metadataFile.readAsString();
        final Map<String, dynamic> json = jsonDecode(contents);

        for (final entry in json.entries) {
          _skinMetadata[entry.key] = WebUIReaMetadata.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }

        _log.fine('Loaded metadata for ${_skinMetadata.length} skins');
      }
    } catch (e) {
      _log.warning('Failed to load skin metadata', e);
    }
  }

  Future<void> _saveSkinMetadata() async {
    try {
      final metadataFile = File('${_webUIDir.path}/.rea_metadata.json');
      final json = <String, dynamic>{};

      for (final entry in _skinMetadata.entries) {
        json[entry.key] = entry.value.toJson();
      }

      await metadataFile.writeAsString(
        JsonEncoder.withIndent('  ').convert(json),
      );
      _log.fine('Saved metadata for ${_skinMetadata.length} skins');
    } catch (e) {
      _log.warning('Failed to save skin metadata', e);
    }
  }

  Future<void> _copyBundledSkins() async {
    for (final assetPath in _bundledAssetPaths) {
      try {
        final skinId = assetPath.split('/').where((s) => s.isNotEmpty).last;
        final destDir = Directory('${_webUIDir.path}/$skinId');

        if (destDir.existsSync() && destDir.listSync().isNotEmpty) {
          _log.fine('Bundled skin already exists: $skinId');
          continue;
        }

        destDir.createSync(recursive: true);

        await _copyAssetFolder(assetPath, destDir.path);

        _log.info('Copied bundled skin: $skinId');
      } catch (e) {
        _log.warning('Failed to copy bundled skin from $assetPath', e);
      }
    }

    List<String> skinIds;
    try {
      final manifestString = await rootBundle.loadString(
        'assets/bundled_skins/manifest.json',
      );
      skinIds = (jsonDecode(manifestString) as List).cast<String>();
    } catch (e, st) {
      _log.warning('Failed to load bundled skins manifest', e, st);
      return;
    }

    await installBundledSkinList(skinIds, (skinId) async {
      final destDir = Directory('${_webUIDir.path}/$skinId');
      if (destDir.existsSync() && destDir.listSync().isNotEmpty) {
        _log.fine('Bundled skin already exists: $skinId');
        return;
      }

      final zipData = await rootBundle.load('assets/bundled_skins/$skinId.zip');
      final tempFile = File('${_webUIDir.path}/$skinId.zip');
      await tempFile.writeAsBytes(zipData.buffer.asUint8List());

      try {
        await _installFromZip(tempFile.path, overwriteIfExists: false);
        _log.info('Installed bundled skin from asset: $skinId');
      } finally {
        if (tempFile.existsSync()) await tempFile.delete();
      }
    }, log: _log);
  }

  Future<void> _copyAssetFolder(String assetPath, String destPath) async {
    try {
      final commonFiles = [
        'index.html',
        'style.css',
        'script.js',
        'app.js',
        'main.js',
        'favicon.ico',
        'manifest.json',
        'README.md',
      ];

      for (final fileName in commonFiles) {
        try {
          final assetFile = '$assetPath$fileName';
          final content = await rootBundle.loadString(assetFile);
          final destFile = File('$destPath/$fileName');
          await destFile.writeAsString(content);
          _log.fine('Copied asset file: $fileName');
        } catch (e) {
          continue;
        }
      }
    } catch (e) {
      _log.warning('Error copying asset folder $assetPath', e);
      rethrow;
    }
  }

  Future<void> _scanInstalledSkins() async {
    final installedSkins = <String, WebUISkin>{};
    final skinPaths = <String, List<String>>{};

    if (!_webUIDir.existsSync()) {
      _installedSkins.clear();
      _skinPaths.clear();
      return;
    }

    final directories = _webUIDir.listSync().whereType<Directory>().where(
      (dir) => p.basename(dir.path) != _stagingDirName,
    );

    for (final dir in directories) {
      try {
        final skinId = p.basename(dir.path);

        final reaMetadata = _skinMetadata[skinId];

        final skinManifestFile = File('${dir.path}/skin-manifest.json');
        final manifestFile = File('${dir.path}/manifest.json');
        WebUISkin skin;

        Map<String, dynamic>? skinMeta;
        if (skinManifestFile.existsSync()) {
          skinMeta = jsonDecode(
            await skinManifestFile.readAsString(),
          ) as Map<String, dynamic>;
        } else if (manifestFile.existsSync()) {
          skinMeta = jsonDecode(
            await manifestFile.readAsString(),
          ) as Map<String, dynamic>;
        }

        if (skinMeta != null) {
          skin = WebUISkin(
            id: skinMeta['id'] as String? ?? skinId,
            name: skinMeta['name'] as String? ?? skinId,
            path: dir.path,
            description: skinMeta['description'] as String?,
            version: skinMeta['version'] as String?,
            isBundled: _isBundledSkin(skinId),
            reaMetadata: reaMetadata,
          );
        } else {
          skin = WebUISkin(
            id: skinId,
            name: skinId,
            path: dir.path,
            isBundled: _isBundledSkin(skinId),
            reaMetadata: reaMetadata,
          );
        }

        if (!isSafePathComponent(skin.id)) {
          _log.warning(
            'Skipping skin with unsafe id "${skin.id}" at ${dir.path}',
          );
          continue;
        }

        (skinPaths[skin.id] ??= []).add(skin.path);
        final existing = installedSkins[skin.id];
        if (existing != null && p.basename(existing.path) == skin.id) {
          continue;
        }
        installedSkins[skin.id] = skin;
        _log.fine('Found skin: ${skin.id} at ${skin.path}');
      } catch (e) {
        _log.warning('Failed to load skin from ${dir.path}', e);
      }
    }
    _installedSkins
      ..clear()
      ..addAll(installedSkins);
    _skinPaths
      ..clear()
      ..addAll(skinPaths);
  }

  bool _isBundledSkin(String skinId) {
    final isAssetBundled = _bundledAssetPaths.any((path) {
      final bundledId = path.split('/').where((s) => s.isNotEmpty).last;
      return bundledId == skinId;
    });

    if (isAssetBundled) return true;

    return _remoteBundledSkinIds.contains(skinId);
  }

  Future<String> _installFromZip(
    String zipPath, {
    bool overwriteIfExists = true,
    String? expectedSkinId,
  }) async {
    _log.info('Installing WebUI from zip: $zipPath');

    final tempDir = await Directory(await AppDirectories.temp)
        .createTemp('webui_extract');

    try {
      final bytes = await File(zipPath).readAsBytes();
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(bytes);
      } catch (e, st) {
        _log.warning('Failed to decode skin archive: $zipPath', e, st);
        throw const UserFacingFormatException(
          'The file is not a valid skin archive.',
        );
      }
      if (archive.files.isEmpty) {
        _log.warning('Skin archive has no entries: $zipPath');
        throw const UserFacingFormatException(
          'The file is not a valid skin archive.',
        );
      }

      final ExtractionResult extraction;
      try {
        extraction = extractArchiveToDirectory(
          archive,
          tempDir,
          sanitize: Platform.isWindows,
          strict: true,
          log: _log,
        );
      } catch (e, st) {
        _log.warning('Failed to extract skin archive: $zipPath', e, st);
        throw const UserFacingFormatException(
          'The skin archive is damaged and could not be extracted.',
        );
      }
      if (extraction.extracted == 0) {
        _log.warning('Skin archive contains no files: $zipPath');
        throw const UserFacingFormatException(
          'The skin archive does not contain any files.',
        );
      }

      return await _installFromDirectory(
        _selectCandidateRoot(tempDir),
        overwriteIfExists: overwriteIfExists,
        expectedSkinId: expectedSkinId,
      );
    } finally {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  Directory _selectCandidateRoot(Directory extractDir) {
    final extractedContents = extractDir.listSync();
    if (extractedContents.length == 1 && extractedContents.first is Directory) {
      return extractedContents.first as Directory;
    }
    return extractDir;
  }

  Future<String> _installFromDirectory(
    Directory sourceDir, {
    bool overwriteIfExists = true,
    String? expectedSkinId,
  }) async {
    final declaredSkinId = await _readCandidateSkinId(sourceDir);
    final skinId =
        expectedSkinId ?? declaredSkinId ?? p.basename(sourceDir.path);

    if (!isSafePathComponent(skinId)) {
      throw const UserFacingFormatException(
        'Unsafe skin id: must be a single safe path component',
      );
    }

    if (skinId == _stagingDirName || declaredSkinId == _stagingDirName) {
      throw const UserFacingFormatException(
        'The skin package declares a reserved skin id.',
      );
    }

    if (expectedSkinId != null &&
        declaredSkinId != null &&
        declaredSkinId != expectedSkinId) {
      throw const UserFacingFormatException(
        'The skin package declares a different skin id than the installed '
        'skin.',
      );
    }

    if (!File('${sourceDir.path}/index.html').existsSync()) {
      throw const UserFacingFormatException(
        'The skin package does not contain an index.html file.',
      );
    }

    final destDir = Directory('${_webUIDir.path}/$skinId');
    final destExists = destDir.existsSync();
    final destHasFiles = destExists && destDir.listSync().isNotEmpty;
    if (destHasFiles && !overwriteIfExists) {
      _log.info(
        'Skin "$skinId" already installed; skipping to avoid clobbering existing copy',
      );
      return skinId;
    }

    await _replaceInstalledSkin(
      sourceDir,
      destDir,
      replaceExisting: destExists,
    );

    _log.info('Installed WebUI skin: $skinId at ${destDir.path}');

    return skinId;
  }

  static const _manifestStringFields = ['id', 'name', 'description', 'version'];

  Future<String?> _readCandidateSkinId(Directory sourceDir) async {
    for (final manifestName in const ['skin-manifest.json', 'manifest.json']) {
      final manifestFile = File('${sourceDir.path}/$manifestName');
      if (!manifestFile.existsSync()) continue;

      final Map<String, dynamic> manifest;
      try {
        manifest = jsonDecode(
          await manifestFile.readAsString(),
        ) as Map<String, dynamic>;
      } catch (e, st) {
        _log.warning(
          'Failed to read $manifestName in ${sourceDir.path}',
          e,
          st,
        );
        throw const UserFacingFormatException(
          'The skin manifest is not valid JSON.',
        );
      }

      for (final field in _manifestStringFields) {
        final value = manifest[field];
        if (value == null || value is String) continue;
        _log.warning(
          'Skin manifest $manifestName in ${sourceDir.path} has a non-string '
          '"$field": $value',
        );
        throw UserFacingFormatException(
          'The skin manifest has an invalid "$field" value.',
        );
      }

      return manifest['id'] as String?;
    }

    return null;
  }

  Future<void> _replaceInstalledSkin(
    Directory sourceDir,
    Directory destDir, {
    required bool replaceExisting,
  }) async {
    final stagingRoot = Directory('${_webUIDir.path}/$_stagingDirName')
      ..createSync(recursive: true);
    Directory? candidate;
    Directory? previous;
    var keepPrevious = false;

    try {
      candidate = stagingRoot.createTempSync('candidate_');
      await copySkinFiles(sourceDir, candidate);

      if (replaceExisting) {
        previous = _reserveDirectoryPath(stagingRoot, 'previous_');
        try {
          await moveSkinDirectory(destDir, previous);
        } catch (e, st) {
          _log.severe('Failed to move aside ${destDir.path}', e, st);
          rethrow;
        }
      }

      try {
        await moveSkinDirectory(candidate, destDir);
        candidate = null;
      } catch (e, st) {
        _log.severe(
          'Failed to move the staged skin into ${destDir.path}',
          e,
          st,
        );
        final movedAside = previous;
        if (movedAside != null) {
          try {
            await moveSkinDirectory(movedAside, destDir);
            previous = null;
          } catch (restoreError, restoreStack) {
            keepPrevious = true;
            _log.severe(
              'Failed to restore the previous skin at ${destDir.path}; '
              'it is preserved at ${movedAside.path}',
              restoreError,
              restoreStack,
            );
          }
        }
        rethrow;
      }
    } finally {
      if (candidate != null) _deleteDirectoryQuietly(candidate);
      if (!keepPrevious && previous != null) {
        _deleteDirectoryQuietly(previous);
      }
      if (stagingRoot.existsSync() && stagingRoot.listSync().isEmpty) {
        _deleteDirectoryQuietly(stagingRoot);
      }
    }
  }

  Directory _reserveDirectoryPath(Directory parent, String prefix) {
    final reserved = parent.createTempSync(prefix);
    reserved.deleteSync();
    return reserved;
  }

  void _deleteDirectoryQuietly(Directory directory) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } catch (e, st) {
      _log.warning('Failed to clean up ${directory.path}', e, st);
    }
  }

  @visibleForTesting
  Future<void> copySkinFiles(Directory source, Directory destination) =>
      _copyDirectory(source, destination);

  @visibleForTesting
  Future<void> moveSkinDirectory(
    Directory source,
    Directory destination,
  ) async {
    await source.rename(destination.path);
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await for (final entity in source.list(recursive: false)) {
      final fileName = p.basename(entity.path);

      if (entity is File) {
        final newFile = File(p.join(destination.path, fileName));
        await entity.copy(newFile.path);
      } else if (entity is Directory) {
        final newDir = Directory(p.join(destination.path, fileName));
        newDir.createSync(recursive: true);
        await _copyDirectory(entity, newDir);
      }
    }
  }

  Future<void> reset() async {
    for (final skin in _installedSkins.values.toList()) {
      if (!skin.isBundled) {
        try {
          await removeSkin(skin.id);
        } catch (e) {
          _log.warning('Failed to remove skin during reset: ${skin.id}', e);
        }
      }
    }

    await _scanInstalledSkins();
  }
}
