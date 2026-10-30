import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/services/github_request.dart';
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

class GitHubReleaseCache {
  static const capacity = 32;
  final _entries = <String, ({String etag, GitHubRelease release})>{};

  void _store(String url, String? etag, GitHubRelease release) {
    if (etag == null || etag.isEmpty) return;
    if (_entries.length == capacity && !_entries.containsKey(url)) {
      _entries.remove(_entries.keys.first);
    }
    _entries[url] = (etag: etag, release: release);
  }
}

Future<GitHubRelease> _fetchRelease(
  String url, {
  required GithubRateLimit rateLimit,
  required GitHubReleaseCache cache,
  bool includePrerelease = false,
}) async {
  final cached = cache._entries[url];
  var response = await githubGet(
    url,
    rateLimit: rateLimit,
    headers: {if (cached != null) 'If-None-Match': cached.etag},
    allowNotModified: true,
  );
  if (response.statusCode == 304) {
    if (cached != null) return cached.release;
    response = await githubGet(url, rateLimit: rateLimit);
  }
  cache._entries.remove(url);
  final decoded = jsonDecode(response.body);
  final GitHubRelease release;
  if (includePrerelease) {
    if (decoded is! List) {
      throw const UserFacingFormatException(
        'GitHub returned invalid release data. Check the source and try again.',
      );
    }
    if (decoded.isEmpty) {
      throw const UserFacingFormatException(
        'No releases published for this repository.',
      );
    }
    release = _releaseFromJson(decoded.first);
  } else {
    release = _releaseFromJson(decoded);
  }
  cache._store(url, response.headers['etag'], release);
  return release;
}

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
  GithubRateLimit? rateLimit,
  GitHubReleaseCache? cache,
}) async {
  validateGitHubRepo(repo);
  final url = includePrerelease
      ? 'https://api.github.com/repos/$repo/releases'
      : 'https://api.github.com/repos/$repo/releases/latest';
  return _fetchRelease(
    url,
    rateLimit: rateLimit ?? GithubRateLimit(),
    cache: cache ?? GitHubReleaseCache(),
    includePrerelease: includePrerelease,
  );
}

Future<GitHubRelease> fetchGitHubReleaseByTag(
  String repo,
  String tag, {
  GithubRateLimit? rateLimit,
  GitHubReleaseCache? cache,
}) async {
  validateGitHubRepo(repo);
  return _fetchRelease(
    'https://api.github.com/repos/$repo/releases/tags/$tag',
    rateLimit: rateLimit ?? GithubRateLimit(),
    cache: cache ?? GitHubReleaseCache(),
  );
}

GitHubRelease _releaseFromJson(Object? release) {
  if (release case {
    'tag_name': final String tag,
    'assets': final List assets,
  } when tag.isNotEmpty) {
    return GitHubRelease(
      tag: tag,
      assets: [
        for (final asset in assets)
          if (asset case {
            'name': final String name,
            'browser_download_url': final String url,
          } when name.isNotEmpty && url.isNotEmpty)
            GitHubAsset(name: name, downloadUrl: url)
          else
            throw const UserFacingFormatException(
              'GitHub returned invalid release assets. Check the source and try again.',
            ),
      ],
    );
  }
  throw const UserFacingFormatException(
    'GitHub returned invalid release data. Check the source and try again.',
  );
}

Future<String> fetchGitHubBranchCommit(
  String repo,
  String branch, {
  GithubRateLimit? rateLimit,
}) async {
  validateGitHubRepo(repo);
  final response = await githubGet(
    'https://api.github.com/repos/$repo/commits/$branch',
    rateLimit: rateLimit ?? GithubRateLimit(),
  );
  if (jsonDecode(response.body) case {
    'sha': final String commit,
  } when commit.isNotEmpty) {
    return commit;
  }
  throw const UserFacingFormatException(
    'GitHub returned no commit for this branch.',
  );
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
