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
    return _releaseFromJson(decoded.first);
  }

  return _releaseFromJson(decoded);
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
  return _releaseFromJson(jsonDecode(response.body));
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
