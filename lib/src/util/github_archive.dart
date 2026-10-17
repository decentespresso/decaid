import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:reaprime/src/util/remote_error.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';

class GitHubAsset {
  final String name;
  final String downloadUrl;

  const GitHubAsset({required this.name, required this.downloadUrl});
}

class GitHubRelease {
  final String tag;
  final List<GitHubAsset> assets;

  const GitHubRelease({required this.tag, required this.assets});

  List<GitHubAsset> get zipAssets =>
      assets.where((a) => a.name.toLowerCase().endsWith('.zip')).toList();
}

const _headers = {
  'Accept': 'application/vnd.github.v3+json',
  'User-Agent': 'Decaid',
};

void validateGitHubRepo(String repo) {
  final parts = repo.split('/');
  if (parts.length != 2 || parts.any((p) => p.isEmpty)) {
    throw const UserFacingFormatException(
      'Invalid GitHub repo. Use: owner/repo',
    );
  }
}

Future<GitHubRelease> fetchLatestGitHubRelease(
  String repo, {
  bool includePrerelease = false,
}) async {
  validateGitHubRepo(repo);
  final url = includePrerelease
      ? 'https://api.github.com/repos/$repo/releases'
      : 'https://api.github.com/repos/$repo/releases/latest';

  final response = await http.get(Uri.parse(url), headers: _headers);
  if (response.statusCode != 200) {
    throw remoteHttpError(response.statusCode);
  }

  final decoded = jsonDecode(response.body);
  final Map<String, dynamic> release;
  if (includePrerelease) {
    final list = (decoded as List).cast<Map<String, dynamic>>();
    if (list.isEmpty) {
      throw const UserFacingFormatException(
        'No releases published for this repository.',
      );
    }
    release = list.first;
  } else {
    release = decoded as Map<String, dynamic>;
  }

  return _releaseFromJson(release);
}

Future<GitHubRelease> fetchGitHubReleaseByTag(String repo, String tag) async {
  validateGitHubRepo(repo);
  final response = await http.get(
    Uri.parse('https://api.github.com/repos/$repo/releases/tags/$tag'),
    headers: _headers,
  );
  if (response.statusCode != 200) {
    throw remoteHttpError(response.statusCode);
  }
  return _releaseFromJson(jsonDecode(response.body) as Map<String, dynamic>);
}

GitHubRelease _releaseFromJson(Map<String, dynamic> release) {
  final assets = ((release['assets'] as List?) ?? [])
      .cast<Map<String, dynamic>>()
      .map(
        (asset) => GitHubAsset(
          name: asset['name'] as String,
          downloadUrl: asset['browser_download_url'] as String,
        ),
      )
      .toList();

  return GitHubRelease(tag: release['tag_name'] as String, assets: assets);
}

Future<String> fetchGitHubBranchCommit(String repo, String branch) async {
  validateGitHubRepo(repo);
  final response = await http.get(
    Uri.parse('https://api.github.com/repos/$repo/commits/$branch'),
    headers: _headers,
  );
  if (response.statusCode != 200) {
    throw remoteHttpError(response.statusCode);
  }
  final commit = (jsonDecode(response.body) as Map<String, dynamic>)['sha'];
  if (commit is! String || commit.isEmpty) {
    throw const UserFacingFormatException(
      'GitHub returned no commit for this branch.',
    );
  }
  return commit;
}

String gitHubCommitArchiveUrl(String repo, String commit) =>
    'https://github.com/$repo/archive/$commit.zip';

Future<List<int>> downloadGitHubArchive(String url) async {
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw remoteHttpError(response.statusCode);
  }
  return response.bodyBytes;
}
