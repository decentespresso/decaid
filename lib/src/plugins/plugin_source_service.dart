import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_package.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/util/github_archive.dart';
import 'package:reaprime/src/webui_support/webui_zip_support.dart';

class PluginApprovalRequiredException implements Exception {
  final String message;
  PluginApprovalRequiredException(this.message);

  @override
  String toString() => message;
}

final _releaseTagPattern = RegExp(r'^v?\d+\.\d+\.\d+$');

class PluginSourceService {
  static const metadataFileName = '.rea_source.json';

  final PluginLoaderService _loader;
  final _log = Logger('PluginSourceService');

  PluginSourceService(this._loader);

  PluginSource? sourceFor(String pluginId) {
    try {
      final file = File(
        '${_loader.getPluginDirectory(pluginId)}/$metadataFileName',
      );
      if (!file.existsSync()) return null;
      return PluginSource.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      );
    } catch (e) {
      _log.fine('No readable source metadata for $pluginId: $e');
      return null;
    }
  }

  void _writeSource(String pluginId, PluginSource source) {
    File(
      '${_loader.getPluginDirectory(pluginId)}/$metadataFileName',
    ).writeAsStringSync(jsonEncode(source.toJson()));
  }

  Future<PluginManifest> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    final release = await fetchLatestGitHubRelease(
      repo,
      includePrerelease: includePrerelease,
    );
    final asset = _selectReleaseAsset(release, assetName);
    final bytes = await downloadGitHubArchive(asset.downloadUrl);

    return _withStaging((staging) async {
      _extractArchive(bytes, staging);
      final package = resolvePluginPackage(staging);
      _requireTagMatchesManifest(release.tag, package.manifest.version);

      final now = DateTime.now();
      return _install(
        package,
        PluginSource(
          kind: PluginSourceKind.githubRelease,
          repo: repo,
          releaseTag: release.tag,
          assetName: assetName,
          includePrerelease: includePrerelease,
          installedAt: now,
          lastChecked: now,
        ),
      );
    });
  }

  Future<PluginManifest> installFromGitHubBranch(
    String repo, {
    String branch = 'main',
  }) async {
    final commit = await fetchGitHubBranchCommit(repo, branch);
    final bytes = await downloadGitHubArchive(
      gitHubBranchArchiveUrl(repo, branch),
    );

    return _withStaging((staging) async {
      _extractArchive(bytes, staging);
      final package = resolvePluginPackage(staging);

      final now = DateTime.now();
      return _install(
        package,
        PluginSource(
          kind: PluginSourceKind.githubBranch,
          repo: repo,
          branch: branch,
          commit: commit,
          installedAt: now,
          lastChecked: now,
        ),
      );
    });
  }

  Future<PluginManifest> installFromZip(String zipPath) async {
    final bytes = await File(zipPath).readAsBytes();
    return _withStaging((staging) async {
      _extractArchive(bytes, staging);
      final package = resolvePluginPackage(staging);
      return _install(
        package,
        PluginSource(
          kind: PluginSourceKind.localZip,
          installedAt: DateTime.now(),
        ),
      );
    });
  }

  Future<PluginManifest> installFromFolder(String folderPath) async {
    final package = resolvePluginPackage(Directory(folderPath));
    return _install(
      package,
      PluginSource(
        kind: PluginSourceKind.localFolder,
        installedAt: DateTime.now(),
      ),
    );
  }

  Future<PluginManifest> _install(
    PluginPackage package,
    PluginSource source, {
    bool allowDowngrade = false,
  }) async {
    final manifest = await _loader.installPluginPackage(
      package.root,
      allowDowngrade: allowDowngrade,
    );
    _writeSource(manifest.id, source);
    return manifest;
  }

  Future<void> updateAllPlugins() async {
    _log.info('Starting update check for managed plugins');

    for (final manifest in _loader.availablePlugins) {
      final source = sourceFor(manifest.id);
      if (source == null || !source.kind.isManaged) continue;

      try {
        await _updatePlugin(manifest, source);
      } catch (e, st) {
        _log.warning('Failed to update plugin "${manifest.id}"', e, st);
        _writeSource(
          manifest.id,
          source.copyWith(lastChecked: DateTime.now(), lastError: '$e'),
        );
      }
    }

    _log.info('Finished update check for managed plugins');
  }

  Future<void> _updatePlugin(
    PluginManifest installed,
    PluginSource source,
  ) async {
    final now = DateTime.now();

    if (source.kind == PluginSourceKind.githubRelease) {
      final release = await fetchLatestGitHubRelease(
        source.repo!,
        includePrerelease: source.includePrerelease,
      );
      if (release.tag == source.releaseTag) {
        _writeSource(
          installed.id,
          source.copyWith(lastChecked: now, clearLastError: true),
        );
        return;
      }

      final asset = _selectReleaseAsset(release, source.assetName);
      final bytes = await downloadGitHubArchive(asset.downloadUrl);
      await _withStaging((staging) async {
        _extractArchive(bytes, staging);
        final package = resolvePluginPackage(staging);
        _requireTagMatchesManifest(release.tag, package.manifest.version);

        final added = _addedPermissions(installed, package.manifest);
        if (added.isNotEmpty) {
          _log.info(
            'Update of ${installed.id} to ${release.tag} needs approval for: '
            '${added.join(', ')}',
          );
          _writeSource(
            installed.id,
            source.copyWith(
              lastChecked: now,
              clearLastError: true,
              pendingUpdate: PluginPendingUpdate(
                version: package.manifest.version,
                releaseTag: release.tag,
                addedPermissions: added,
                detectedAt: now,
              ),
            ),
          );
          return;
        }

        await _install(
          package,
          PluginSource(
            kind: PluginSourceKind.githubRelease,
            repo: source.repo,
            releaseTag: release.tag,
            assetName: source.assetName,
            includePrerelease: source.includePrerelease,
            installedAt: now,
            lastChecked: now,
          ),
        );
      });
      return;
    }

    final branch = source.branch ?? 'main';
    final commit = await fetchGitHubBranchCommit(source.repo!, branch);
    if (commit == source.commit) {
      _writeSource(
        installed.id,
        source.copyWith(lastChecked: now, clearLastError: true),
      );
      return;
    }

    final bytes = await downloadGitHubArchive(
      gitHubBranchArchiveUrl(source.repo!, branch),
    );
    await _withStaging((staging) async {
      _extractArchive(bytes, staging);
      final package = resolvePluginPackage(staging);

      final added = _addedPermissions(installed, package.manifest);
      if (added.isNotEmpty) {
        _log.info(
          'Update of ${installed.id} to $commit needs approval for: '
          '${added.join(', ')}',
        );
        _writeSource(
          installed.id,
          source.copyWith(
            lastChecked: now,
            clearLastError: true,
            pendingUpdate: PluginPendingUpdate(
              version: package.manifest.version,
              commit: commit,
              addedPermissions: added,
              detectedAt: now,
            ),
          ),
        );
        return;
      }

      await _install(
        package,
        PluginSource(
          kind: PluginSourceKind.githubBranch,
          repo: source.repo,
          branch: branch,
          commit: commit,
          installedAt: now,
          lastChecked: now,
        ),
        allowDowngrade: true,
      );
    });
  }

  Future<PluginManifest> approvePendingUpdate(String pluginId) async {
    final source = sourceFor(pluginId);
    if (source == null || source.pendingUpdate == null) {
      throw PluginApprovalRequiredException(
        'Plugin $pluginId has no update awaiting approval',
      );
    }

    if (source.kind == PluginSourceKind.githubRelease) {
      return installFromGitHubRelease(
        source.repo!,
        assetName: source.assetName,
        includePrerelease: source.includePrerelease,
      );
    }
    return installFromGitHubBranch(
      source.repo!,
      branch: source.branch ?? 'main',
    );
  }

  List<String> _addedPermissions(
    PluginManifest installed,
    PluginManifest candidate,
  ) {
    final added = candidate.permissions.difference(installed.permissions);
    return added.map((p) => p.wireName).toList()..sort();
  }

  GitHubAsset _selectReleaseAsset(GitHubRelease release, String? assetName) {
    if (assetName != null) {
      final match = release.assets.where((a) => a.name == assetName);
      if (match.isEmpty) {
        throw PluginPackageException(
          'Release ${release.tag} has no asset named "$assetName"',
        );
      }
      return match.first;
    }

    final zips = release.zipAssets;
    if (zips.isEmpty) {
      throw PluginPackageException(
        'Release ${release.tag} has no .zip asset to install',
      );
    }
    if (zips.length > 1) {
      throw PluginPackageException(
        'Release ${release.tag} has ${zips.length} .zip assets '
        '(${zips.map((a) => a.name).join(', ')}); name the one to install',
      );
    }
    return zips.single;
  }

  void _requireTagMatchesManifest(String tag, String manifestVersion) {
    if (!_releaseTagPattern.hasMatch(tag)) {
      throw PluginPackageException('Release tag "$tag" is not X.Y.Z or vX.Y.Z');
    }
    final normalized = tag.startsWith('v') ? tag.substring(1) : tag;
    if (normalized != manifestVersion) {
      throw PluginPackageException(
        'Release tag "$tag" does not match manifest version '
        '"$manifestVersion"',
      );
    }
  }

  void _extractArchive(List<int> bytes, Directory destination) {
    final archive = ZipDecoder().decodeBytes(bytes);
    extractArchiveToDirectory(
      archive,
      destination,
      sanitize: Platform.isWindows,
      log: _log,
    );
  }

  Future<T> _withStaging<T>(Future<T> Function(Directory staging) body) async {
    final staging = await Directory.systemTemp.createTemp('decaid_plugin_');
    try {
      return await body(staging);
    } finally {
      if (staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (e) {
          _log.warning('Failed to clean plugin staging ${staging.path}', e);
        }
      }
    }
  }
}
