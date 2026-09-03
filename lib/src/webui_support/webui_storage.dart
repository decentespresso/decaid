import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
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
  final SettingsController _settingsController;
  final Directory? _webUIDirOverride;

  late Directory _webUIDir;
  final Map<String, WebUISkin> _installedSkins = {};
  final Map<String, WebUIReaMetadata> _skinMetadata = {};
  bool _initialized = false;

  WebUIStorage(this._settingsController, {Directory? webUIDir})
    : _webUIDirOverride = webUIDir;

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
      await downloadRemoteSkins();
    }

    await _scanInstalledSkins();

    _initialized = true;
    _log.info('WebUIStorage initialized with ${_installedSkins.length} skins');
  }

  List<WebUISkin> get installedSkins => _installedSkins.values.toList();

  WebUISkin? getSkin(String id) => _installedSkins[id];

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
  }) async {
    _log.info('Downloading WebUI from URL: $url');

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('Failed to download: ${response.statusCode}');
      }
      final etag = response.headers['etag'];
      final lastModified = response.headers['last-modified'];

      final tempDir = await Directory(
        await AppDirectories.temp,
      ).createTemp('webui_install');
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
      throw Exception('Invalid GitHub repo format. Use: owner/repo');
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
      throw Exception('Invalid GitHub repo format. Use: owner/repo');
    }

    _log.info('Installing WebUI from GitHub release: $repo');

    try {
      final apiUrl = includePrerelease
          ? 'https://api.github.com/repos/$repo/releases'
          : 'https://api.github.com/repos/$repo/releases/latest';

      final releaseResponse = await http.get(
        Uri.parse(apiUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'Decent-WebUI',
        },
      );

      if (releaseResponse.statusCode != 200) {
        throw Exception(
          'Failed to fetch GitHub release: ${releaseResponse.statusCode}',
        );
      }

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
          orElse: () => throw Exception('Asset not found: $assetName'),
        );
      } else {
        targetAsset = assets.firstWhere(
          (asset) => (asset['name'] as String).endsWith('.zip'),
          orElse: () => throw Exception('No .zip asset found in release'),
        );
      }

      final downloadUrl = targetAsset['browser_download_url'] as String;

      _log.info('Downloading asset: ${targetAsset['name']}');

      await installFromUrl(
        downloadUrl,
        sourceIdentifier: 'github_release:$repo@$releaseTag',
        releaseAssetName: assetName,
        includePrerelease: includePrerelease,
      );

      _log.info(
        'Successfully installed WebUI from GitHub release: $releaseTag',
      );
    } catch (e) {
      _log.severe('Failed to install WebUI from GitHub release: $repo', e);
      rethrow;
    }
  }

  Future<void> downloadRemoteSkins() async {
    final sources = await _getRemoteWebUISources();
    for (final sourceConfig in sources) {
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
            await _installFromGitHubRelease(repo, asset, prerelease);
            break;

          case 'github_branch':
            final repo = sourceConfig['repo'] as String;
            final branch = sourceConfig['branch'] as String? ?? 'main';
            final url =
                'https://github.com/$repo/archive/refs/heads/$branch.zip';

            _log.info(
              'Downloading remote bundled skin from GitHub branch: $repo/$branch',
            );
            await _installFromUrlAsRemoteBundled(url);
            break;

          case 'url':
            final url = sourceConfig['url'] as String;

            _log.info('Downloading remote bundled skin from URL: $url');
            await _installFromUrlAsRemoteBundled(url);
            break;

          default:
            _log.warning('Unknown remote source type: $type');
        }
      } catch (e, st) {
        _log.warning(
          'Failed to download remote skin from $sourceConfig',
          e,
          st,
        );
      }
    }
  }

  Future<void> downloadRemoteSkinsAndRescan() async {
    await downloadRemoteSkins();
    await _scanInstalledSkins();
  }

  Future<void> updateAllSkins() async {
    _log.info('Starting update check for all skins');

    try {
      await downloadRemoteSkins();
    } catch (e, st) {
      _log.warning('Failed to update remote-bundled skins', e, st);
    }

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
          await _installFromGitHubRelease(
            repo,
            entry.value.releaseAssetName,
            entry.value.includePrerelease ?? false,
            markAsRemoteBundled: false,
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
          await installFromGitHub(repo, branch: branch);
        } else if (sourceUrl.startsWith('http')) {
          _log.info(
            'Updating user-installed skin "$skinId" from URL: $sourceUrl',
          );
          await _installFromUrlAsRemoteBundled(
            sourceUrl,
            markAsRemoteBundled: false,
          );
        } else {
          _log.fine(
            'Skipping skin "$skinId" with unsupported source type: $sourceUrl',
          );
        }
      } catch (e, st) {
        _log.warning('Failed to update skin "$skinId" from $sourceUrl', e, st);
      }
    }

    await _scanInstalledSkins();
    _log.info('Finished update check for all skins');
  }

  Future<void> _installFromGitHubRelease(
    String repo,
    String? assetName,
    bool includePrerelease, {
    bool markAsRemoteBundled = true,
  }) async {
    try {
      final apiUrl = includePrerelease
          ? 'https://api.github.com/repos/$repo/releases'
          : 'https://api.github.com/repos/$repo/releases/latest';

      _log.fine('Fetching GitHub release info from: $apiUrl');

      final releaseResponse = await http.get(
        Uri.parse(apiUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'Decent-WebUI',
        },
      );

      if (releaseResponse.statusCode != 200) {
        throw Exception(
          'Failed to fetch GitHub release: ${releaseResponse.statusCode}',
        );
      }

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
          orElse: () => throw Exception('Asset not found: $assetName'),
        );
      } else {
        targetAsset = assets.firstWhere(
          (asset) => (asset['name'] as String).endsWith('.zip'),
          orElse: () => throw Exception('No .zip asset found in release'),
        );
      }

      final downloadUrl = targetAsset['browser_download_url'] as String;
      final assetSize = targetAsset['size'] as int;

      _log.info(
        'Downloading asset: ${targetAsset['name']} (${(assetSize / 1024 / 1024).toStringAsFixed(2)} MB)',
      );

      final sourceIdentifier = 'github_release:$repo@$releaseTag';
      final existingMetadata = _skinMetadata.values.firstWhere(
        (meta) => meta.sourceUrl == sourceIdentifier,
        orElse: () => WebUIReaMetadata(skinId: '', installedAt: DateTime.now()),
      );

      if (existingMetadata.skinId.isNotEmpty) {
        _log.info('Release $releaseTag already installed, skipping download');

        _skinMetadata[existingMetadata.skinId] = existingMetadata.copyWith(
          lastChecked: DateTime.now(),
        );
        await _saveSkinMetadata();
        return;
      }

      final assetResponse = await http.get(Uri.parse(downloadUrl));
      if (assetResponse.statusCode != 200) {
        throw Exception(
          'Failed to download asset: ${assetResponse.statusCode}',
        );
      }

      final tempDir = await Directory(
        await AppDirectories.temp,
      ).createTemp('webui_install');
      final tempFile = File('${tempDir.path}/skin.zip');
      await tempFile.writeAsBytes(assetResponse.bodyBytes);

      String installedSkinId;
      try {
        installedSkinId = await _installFromZip(tempFile.path);
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
    } catch (e, st) {
      _log.severe('Failed to install from GitHub release: $repo', e, st);
      rethrow;
    }
  }

  Future<void> _installFromUrlAsRemoteBundled(
    String url, {
    bool markAsRemoteBundled = true,
    String? sourceIdentifier,
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

        _skinMetadata[existingMetadata.skinId] = existingMetadata.copyWith(
          lastChecked: DateTime.now(),
        );
        await _saveSkinMetadata();
      }

      if (!needsUpdate) {
        return;
      }

      _log.info('Downloading WebUI from URL: $url');

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('Failed to download: ${response.statusCode}');
      }

      final tempDir = await Directory(
        await AppDirectories.temp,
      ).createTemp('webui_install');
      final tempFile = File('${tempDir.path}/skin.zip');
      await tempFile.writeAsBytes(response.bodyBytes);

      String? commitHash;

      if (url.contains('github.com')) {
        commitHash = _extractGitHubCommitHash(url);
      }

      String installedSkinId;
      try {
        installedSkinId = await _installFromZip(tempFile.path);
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
    _installedSkins.clear();

    if (!_webUIDir.existsSync()) {
      return;
    }

    final directories = _webUIDir.listSync().whereType<Directory>();

    for (final dir in directories) {
      try {
        final skinId = p.basename(dir.path);

        final reaMetadata = _skinMetadata[skinId];

        final skinManifestFile = File('${dir.path}/skin-manifest.json');
        final manifestFile = File('${dir.path}/manifest.json');
        WebUISkin skin;

        Map<String, dynamic>? skinMeta;
        if (skinManifestFile.existsSync()) {
          skinMeta =
              jsonDecode(await skinManifestFile.readAsString())
                  as Map<String, dynamic>;
        } else if (manifestFile.existsSync()) {
          skinMeta =
              jsonDecode(await manifestFile.readAsString())
                  as Map<String, dynamic>;
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

        _installedSkins[skin.id] = skin;
        _log.fine('Found skin: ${skin.id} at ${skin.path}');
      } catch (e) {
        _log.warning('Failed to load skin from ${dir.path}', e);
      }
    }
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
  }) async {
    _log.info('Installing WebUI from zip: $zipPath');

    final tempDir = await Directory(
      await AppDirectories.temp,
    ).createTemp('webui_extract');

    try {
      final zipFile = File(zipPath);
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      extractArchiveToDirectory(
        archive,
        tempDir,
        sanitize: Platform.isWindows,
        log: _log,
      );

      final extractedContents = tempDir.listSync();
      Directory contentDir;

      if (extractedContents.length == 1 &&
          extractedContents.first is Directory) {
        contentDir = extractedContents.first as Directory;
      } else {
        contentDir = tempDir;
      }

      return await _installFromDirectory(
        contentDir,
        overwriteIfExists: overwriteIfExists,
      );
    } finally {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  Future<String> _installFromDirectory(
    Directory sourceDir, {
    bool overwriteIfExists = true,
  }) async {
    String skinId;
    final skinManifestFile = File('${sourceDir.path}/skin-manifest.json');
    final manifestFile = File('${sourceDir.path}/manifest.json');

    if (skinManifestFile.existsSync()) {
      final skinManifestJson = jsonDecode(
        await skinManifestFile.readAsString(),
      );
      skinId = skinManifestJson['id'] as String? ?? p.basename(sourceDir.path);
    } else if (manifestFile.existsSync()) {
      final manifestJson = jsonDecode(await manifestFile.readAsString());
      skinId = manifestJson['id'] as String? ?? p.basename(sourceDir.path);
    } else {
      skinId = p.basename(sourceDir.path);
    }

    if (!isSafePathComponent(skinId)) {
      throw FormatException(
        'Unsafe skin id "$skinId": must be a single safe path component',
      );
    }

    final destDir = Directory('${_webUIDir.path}/$skinId');
    if (destDir.existsSync() &&
        destDir.listSync().isNotEmpty &&
        !overwriteIfExists) {
      _log.info(
        'Skin "$skinId" already installed; skipping to avoid clobbering existing copy',
      );
      return skinId;
    }
    if (destDir.existsSync()) {
      _log.info('Skin already exists: $skinId, overwriting...');
      await destDir.delete(recursive: true);
    }

    destDir.createSync(recursive: true);

    await _copyDirectory(sourceDir, destDir);

    _log.info('Installed WebUI skin: $skinId at ${destDir.path}');

    return skinId;
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
