import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:reaprime/src/services/apk_installer.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;
  final bool isPrerelease;
  final String tagName;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.isPrerelease,
    required this.tagName,
  });

  factory UpdateInfo.fromGitHubRelease(Map<String, dynamic> json) {
    final tagName = json['tag_name'] as String;
    final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;

    final assets = json['assets'] as List<dynamic>;
    final apkAsset = assets.firstWhere(
      (asset) => (asset['name'] as String).endsWith('.apk'),
      orElse: () => throw Exception('No APK found in release'),
    );

    return UpdateInfo(
      version: version,
      downloadUrl: apkAsset['browser_download_url'] as String,
      releaseNotes: json['body'] as String? ?? '',
      isPrerelease: json['prerelease'] as bool,
      tagName: tagName,
    );
  }
}

enum UpdateChannel { stable, beta }

class AndroidUpdater {
  final Logger _log = Logger('AndroidUpdater');
  final String _owner;
  final String _repo;
  final http.Client _httpClient;
  final ApkInstaller _apkInstaller;

  AndroidUpdater({
    required String owner,
    required String repo,
    http.Client? httpClient,
    ApkInstaller? apkInstaller,
  }) : _owner = owner,
       _repo = repo,
       _httpClient = httpClient ?? http.Client(),
       _apkInstaller = apkInstaller ?? ApkInstaller();

  String get _releasesUrl =>
      'https://api.github.com/repos/$_owner/$_repo/releases';

  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    try {
      _log.info(
        'Checking for updates on $channel channel (current: $currentVersion)',
      );

      final response = await _httpClient.get(Uri.parse(_releasesUrl));

      if (response.statusCode != 200) {
        _log.warning('Failed to fetch releases: ${response.statusCode}');
        return null;
      }

      final releases = json.decode(response.body) as List<dynamic>;

      if (releases.isEmpty) {
        _log.info('No releases found');
        return null;
      }

      final matchingReleases =
          releases
              .map((release) => _parseRelease(release, channel))
              .whereType<UpdateInfo>()
              .toList()
            ..sort(
              (a, b) =>
                  Version.parse(b.version).compareTo(Version.parse(a.version)),
            );

      if (matchingReleases.isEmpty) {
        _log.info('No releases found for $channel channel');
        return null;
      }

      final updateInfo = matchingReleases.first;

      if (_isNewerVersion(updateInfo.version, currentVersion)) {
        _log.info('Update available: ${updateInfo.version}');
        return updateInfo;
      } else {
        _log.info('Already on latest version');
        return null;
      }
    } catch (e, stackTrace) {
      _log.severe('Error checking for updates', e, stackTrace);
      return null;
    }
  }

  Future<String> downloadUpdate(
    UpdateInfo updateInfo, {
    Function(double progress)? onProgress,
    Directory? cacheDir,
  }) async {
    try {
      _log.info('Downloading update from ${updateInfo.downloadUrl}');

      final request = http.Request('GET', Uri.parse(updateInfo.downloadUrl));
      final response = await _httpClient.send(request);

      if (response.statusCode != 200) {
        throw Exception('Failed to download update: ${response.statusCode}');
      }

      final total = response.contentLength;
      final bytes = <int>[];
      var received = 0;
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (onProgress != null && total != null && total > 0) {
          onProgress(received / total);
        }
      }

      final dir = cacheDir ?? await getTemporaryDirectory();
      final apkPath = '${dir.path}/update_${updateInfo.version}.apk';
      final apkFile = File(apkPath);

      await apkFile.writeAsBytes(bytes);

      _log.info('Downloaded update to $apkPath');
      return apkPath;
    } catch (e, stackTrace) {
      _log.severe('Error downloading update', e, stackTrace);
      rethrow;
    }
  }

  Future<bool> installUpdate(String apkPath) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('APK installation is only supported on Android');
    }

    try {
      _log.info('Installing update from $apkPath');

      final canInstall = await _apkInstaller.canInstallPackages();
      if (!canInstall) {
        _log.warning(
          'No permission to install packages, requesting permission',
        );
        await _apkInstaller.requestInstallPermission();
        return false;
      }

      return await _apkInstaller.installApk(apkPath);
    } catch (e, stackTrace) {
      _log.severe('Error installing update', e, stackTrace);
      rethrow;
    }
  }

  UpdateInfo? _parseRelease(Object? release, UpdateChannel channel) {
    try {
      final json = release as Map<String, dynamic>;
      final isPrerelease = json['prerelease'] as bool;
      if (channel == UpdateChannel.stable && isPrerelease) return null;
      final update = UpdateInfo.fromGitHubRelease(json);
      Version.parse(update.version);
      return update;
    } catch (e) {
      _log.warning('Skipping unsupported GitHub release: $e');
      return null;
    }
  }

  bool _isNewerVersion(String newVersion, String currentVersion) {
    try {
      return Version.parse(
            newVersion,
          ).compareTo(Version.parse(currentVersion)) >
          0;
    } catch (e) {
      _log.warning('Error comparing versions: $e');
      return false;
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
