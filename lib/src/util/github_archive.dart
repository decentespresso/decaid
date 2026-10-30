import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:reaprime/src/services/github_rate_limit.dart';
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

final _cachedReleaseEtags = <String, String>{};
final _cachedReleases = <String, GitHubRelease>{};

RemoteServiceException _githubRateLimited(DateTime? resetAt) {
  if (resetAt == null) {
    return RemoteServiceException(
      429,
      'GitHub updates are temporarily unavailable. Try again later.',
    );
  }
  final utc = resetAt.toUtc();
  final hour = utc.hour.toString().padLeft(2, '0');
  final minute = utc.minute.toString().padLeft(2, '0');
  return RemoteServiceException(
    429,
    'GitHub updates are temporarily unavailable until $hour:$minute UTC. '
    'Try again later.',
  );
}

Map<String, String> _releaseHeaders(String url) {
  final headers = Map<String, String>.from(_headers);
  final etag = _cachedReleaseEtags[url];
  if (etag != null) {
    headers['If-None-Match'] = etag;
  }
  return headers;
}

Future<http.Response> _rateLimitedGet(
  String url,
  GithubRateLimit? rateLimit,
) async {
  final limitedAt = rateLimit?.resetAt;
  if (limitedAt != null) {
    throw _githubRateLimited(limitedAt);
  }
  final response = await http.get(
    Uri.parse(url),
    headers: _releaseHeaders(url),
  );
  if (response.statusCode != 200 && response.statusCode != 304) {
    final holder = rateLimit;
    if (holder != null && holder.recordIfLimited(response)) {
      throw _githubRateLimited(holder.resetAt);
    }
    throw remoteHttpError(response.statusCode);
  }
  return response;
}

GitHubRelease? _cachedRelease(String url, http.Response response) {
  if (response.statusCode != 304) {
    return null;
  }
  return _cachedReleases[url];
}

void _storeRelease(String url, http.Response response, GitHubRelease release) {
  final etag = response.headers['etag'];
  if (etag != null && etag.isNotEmpty) {
    _cachedReleaseEtags[url] = etag;
    _cachedReleases[url] = release;
  }
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
}) async {
  validateGitHubRepo(repo);
  final url = includePrerelease
      ? 'https://api.github.com/repos/$repo/releases'
      : 'https://api.github.com/repos/$repo/releases/latest';

  final response = await _rateLimitedGet(url, rateLimit);
  final notModified = _cachedRelease(url, response);
  if (notModified != null) {
    return notModified;
  }

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
  _storeRelease(url, response, release);
  return release;
}

Future<GitHubRelease> fetchGitHubReleaseByTag(
  String repo,
  String tag, {
  GithubRateLimit? rateLimit,
}) async {
  validateGitHubRepo(repo);
  final url = 'https://api.github.com/repos/$repo/releases/tags/$tag';
  final response = await _rateLimitedGet(url, rateLimit);
  final notModified = _cachedRelease(url, response);
  if (notModified != null) {
    return notModified;
  }
  final release = _releaseFromJson(jsonDecode(response.body));
  _storeRelease(url, response, release);
  return release;
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

Future<String> fetchGitHubBranchCommit(String repo, String branch) async {
  validateGitHubRepo(repo);
  final response = await http.get(
    Uri.parse('https://api.github.com/repos/$repo/commits/$branch'),
    headers: _headers,
  );
  if (response.statusCode != 200) {
    throw remoteHttpError(response.statusCode);
  }
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
