import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/models/feedback/feedback_result.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_request.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';
import 'package:reaprime/src/services/telemetry/anonymization.dart';
import 'package:reaprime/src/util/remote_error.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';

class FeedbackAttachmentException implements UserFacingException {
  @override
  final String message;

  const FeedbackAttachmentException(this.message);

  @override
  String toString() => message;
}

class _SupportReferenceException implements Exception {
  final String message;

  const _SupportReferenceException(this.message);

  @override
  String toString() => message;
}

class FeedbackService {
  final String _githubToken;
  final String _repo;
  final List<String> Function() _currentSerialNumbers;
  final List<String> Function() _installedComponents;
  final DecentAccountService? _accountService;
  final Duration _supportLinkTimeout;
  final GithubCredentialProvider? _credentials;
  final http.Client? _httpClient;
  final Logger _log = Logger('FeedbackService');

  static const String _githubApiBase = 'https://api.github.com';

  FeedbackService({
    required this._githubToken,
    this._repo = 'decentespresso/decaid',
    required this._currentSerialNumbers,
    List<String> Function()? installedComponents,
    this._accountService,
    this._supportLinkTimeout = const Duration(seconds: 30),
    this._credentials,
    this._httpClient,
  }) : _installedComponents = installedComponents ?? _noComponents;

  bool get isConfigured =>
      _githubToken.isNotEmpty || _credentials?.current.isUser == true;

  Future<FeedbackSubmissionResult> submitFeedback(
    FeedbackRequest request,
  ) async {
    final GithubCredentialSnapshot authorization;
    try {
      authorization = await _feedbackSnapshot();
    } catch (_) {
      return FeedbackSubmissionResult.failed(
        'Could not read the GitHub credential. Open Advanced Settings to replace or remove it.',
      );
    }

    final DecentAccountStatus accountStatus;
    try {
      accountStatus =
          await _accountService?.verifyStoredCredentialsStatus() ??
          DecentAccountStatus.unauthenticated;
    } catch (_) {
      _log.warning('Could not verify Decent account for feedback');
      return FeedbackSubmissionResult.failed(
        'Could not verify your Decent account. Check your connection and try again.',
        reason: FeedbackFailureReason.accountRequired,
      );
    }
    if (accountStatus != DecentAccountStatus.authenticated) {
      return FeedbackSubmissionResult.failed(
        accountStatus == DecentAccountStatus.indeterminate
            ? 'Could not verify your Decent account. Check your connection and try again.'
            : 'You must be logged in to your Decent account to submit feedback.',
        reason: FeedbackFailureReason.accountRequired,
      );
    }

    if (authorization.isAnonymous) {
      return FeedbackSubmissionResult.failed(
        'Feedback service is not configured. Open Advanced Settings to add a GitHub token or build with a feedback token.',
      );
    }

    try {
      _log.info('Submitting ${request.type.name} feedback');

      String systemInfo = '';
      if (request.includeSystemInfo) {
        systemInfo = _collectSystemInfo();
      }

      String? gistUrl;
      if (request.includeLogs || request.screenshots.isNotEmpty) {
        gistUrl = await _uploadGist(
          includeLogs: request.includeLogs,
          screenshots: request.screenshots,
          authorization: authorization,
        );
      }

      final body = _buildIssueBody(
        request: request,
        systemInfo: systemInfo,
        gistUrl: gistUrl,
        authorization: authorization,
      );

      final issueResult = await _createGitHubIssue(
        title: _buildIssueTitle(request, authorization: authorization),
        body: body,
        labels: _buildLabels(request),
        authorization: authorization,
      );

      if (issueResult == null) {
        return FeedbackSubmissionResult.failed('Failed to create GitHub issue');
      }

      final issueNumber = issueResult['number'] as int;
      final issueUrl = _safeIssueUrl(issueResult['html_url'], issueNumber);

      final supportLinkAbort = Completer<void>();
      var supportLinked = false;
      String? supportWarning;
      try {
        supportLinked =
            await _linkFeedbackToSupport(
              issueNumber: issueNumber,
              issueUrl: issueUrl,
              authorization: authorization,
              abort: supportLinkAbort,
            ).timeout(
              _supportLinkTimeout,
              onTimeout: () {
                if (!supportLinkAbort.isCompleted) supportLinkAbort.complete();
                throw TimeoutException('Decent Support linking timed out');
              },
            );
      } catch (e) {
        _log.warning('Could not link feedback to Decent support');
        supportWarning = e is _SupportReferenceException ? e.message : 'Feedback was created, but Decent Support linking did not finish. Check your connection; the issue is available on GitHub.';
      }

      _log.info('Feedback submitted successfully as issue #$issueNumber');
      return FeedbackSubmissionResult.succeeded(
        issueUrl: issueUrl,
        issueNumber: issueNumber,
        supportLink: supportWarning != null
            ? 'failed'
            : supportLinked
            ? 'linked'
            : null,
        warning: supportWarning,
      );
    } catch (e) {
      _log.severe('Failed to submit feedback');
      return FeedbackSubmissionResult.failed(_safeFeedbackError(e));
    }
  }

  Future<GithubCredentialSnapshot> _feedbackSnapshot() async {
    if (_credentials != null) {
      return _credentials.feedbackSnapshot(bundledToken: _githubToken);
    }
    final token = _githubToken.trim();
    return token.isEmpty
        ? const GithubCredentialSnapshot.anonymous()
        : GithubCredentialSnapshot.bundled(token);
  }

  String _safeFeedbackError(Object error) {
    if (error is GithubRequestException) return error.userMessage;
    if (error is FeedbackAttachmentException) return error.message;
    return remoteErrorMessage(error, action: 'send feedback');
  }

  String _safeIssueUrl(Object? value, int issueNumber) {
    final parsed = value is String ? Uri.tryParse(value) : null;
    if (parsed != null &&
        parsed.scheme == 'https' &&
        parsed.host == 'github.com' &&
        parsed.userInfo.isEmpty &&
        parsed.query.isEmpty &&
        parsed.fragment.isEmpty &&
        parsed.path == '/$_repo/issues/$issueNumber') {
      return parsed.toString();
    }
    return 'https://github.com/$_repo/issues/$issueNumber';
  }

  Map<String, String> _githubHeaders(
    Uri uri,
    GithubCredentialSnapshot authorization, {
    bool json = false,
  }) {
    return githubRequestHeaders(
      uri,
      authorization: authorization,
      headers: {if (json) 'Content-Type': 'application/json'},
    );
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) {
    final client = _httpClient;
    return client == null ? request.send() : client.send(request);
  }

  Future<http.Response> _sendJson({
    required String method,
    required Uri uri,
    required Object body,
    required GithubCredentialSnapshot authorization,
  }) async {
    final request = http.Request(method, uri)
      ..headers.addAll(_githubHeaders(uri, authorization, json: true))
      ..followRedirects = false
      ..body = jsonEncode(body);
    return http.Response.fromStream(await _send(request));
  }

  String _collectSystemInfo() {
    final info = StringBuffer();
    info.writeln('**System Information:**');
    info.writeln(
      '- App Version: ${BuildInfo.version} (build ${BuildInfo.buildNumber})',
    );
    info.writeln('- Commit: ${BuildInfo.commitShort}');
    info.writeln('- Branch: ${BuildInfo.branch}');
    info.writeln('- Platform: ${Platform.operatingSystem}');
    info.writeln('- OS Version: ${Platform.operatingSystemVersion}');
    info.writeln('- Dart Version: ${Platform.version}');
    for (final component in _readInstalledComponents()) {
      info.writeln('- $component');
    }
    return info.toString();
  }

  List<String> _readInstalledComponents() {
    try {
      return _installedComponents();
    } catch (e, st) {
      _log.warning('Could not read installed component versions', e, st);
      return const [];
    }
  }

  Future<String?> _uploadGist({
    required bool includeLogs,
    required List<Uint8List> screenshots,
    required GithubCredentialSnapshot authorization,
  }) async {
    try {
      final Map<String, Map<String, String>> gistFiles = {};

      if (includeLogs) {
        String? logContent = await _readLogFile(authorization: authorization);
        if (logContent != null && logContent.isNotEmpty) {
          const maxLogSize = 500000;
          if (logContent.length > maxLogSize) {
            logContent =
                '... (truncated, showing last ${maxLogSize ~/ 1024}KB) ...\n${logContent.substring(logContent.length - maxLogSize)}';
          }
          gistFiles['decent_logs.txt'] = {'content': logContent};
        }

        String? webViewLogContent = await _readWebViewLogFile(
          authorization: authorization,
        );
        if (webViewLogContent != null && webViewLogContent.isNotEmpty) {
          const maxWebViewLogSize = 500000;
          if (webViewLogContent.length > maxWebViewLogSize) {
            webViewLogContent =
                '... (truncated, showing last ${maxWebViewLogSize ~/ 1024}KB) ...\n${webViewLogContent.substring(webViewLogContent.length - maxWebViewLogSize)}';
          }
          gistFiles['decent_webview_logs.txt'] = {'content': webViewLogContent};
        }
      }

      for (int i = 0; i < screenshots.length; i++) {
        final scaled = await _scaleImageToMaxSize(screenshots[i], 48000);
        final base64 = base64Encode(scaled);
        gistFiles['screenshot_${i + 1}.png.b64'] = {'content': base64};
      }

      if (gistFiles.isEmpty) {
        return null;
      }

      final response = await _sendJson(
        method: 'POST',
        uri: Uri.parse('$_githubApiBase/gists'),
        authorization: authorization,
        body: {
          'description':
              'Decent feedback - ${DateTime.now().toIso8601String()}',
          'public': false,
          'files': gistFiles,
        },
      );

      if (response.statusCode == 201) {
        final gistData = jsonDecode(response.body) as Map<String, dynamic>;
        final gistUrl = gistData['html_url'] as String;
        final parsed = Uri.tryParse(gistUrl);
        final segments = parsed?.pathSegments ?? const <String>[];
        final validGistPath =
            segments.length == 2 &&
            RegExp(r'^[A-Za-z0-9-]+$').hasMatch(segments[0]) &&
            RegExp(r'^[0-9a-fA-F]{8,}$').hasMatch(segments[1]);
        if (parsed == null ||
            parsed.scheme != 'https' ||
            parsed.host != 'gist.github.com' ||
            parsed.userInfo.isNotEmpty ||
            parsed.query.isNotEmpty ||
            parsed.fragment.isNotEmpty ||
            !validGistPath ||
            _scrubSensitive(parsed.toString(), authorization: authorization) !=
                parsed.toString()) {
          throw const FeedbackAttachmentException(
            'GitHub returned an invalid attachment URL. Retry or uncheck logs/remove screenshots.',
          );
        }
        _log.info('Gist uploaded');
        return parsed.toString();
      }
      throw _attachmentException(authorization);
    } catch (e) {
      if (e is FeedbackAttachmentException) rethrow;
      _log.warning('Failed to upload Gist');
      throw _attachmentException(authorization);
    }
  }

  FeedbackAttachmentException _attachmentException(
    GithubCredentialSnapshot authorization,
  ) {
    final credentialAdvice = authorization.isUser
        ? ' If this is your PAT, open Advanced Settings to replace or remove it.'
        : '';
    return FeedbackAttachmentException(
      'Could not upload attachments. Check Gists write permission, then retry or uncheck logs/remove screenshots.$credentialAdvice',
    );
  }

  Future<String?> _readLogFile({
    GithubCredentialSnapshot? authorization,
  }) async {
    try {
      final logFile = File('${await AppDirectories.logs}/log.txt');
      if (await logFile.exists()) {
        return _scrubSensitive(
          await logFile.readAsString(),
          authorization: authorization,
        );
      }
      _log.info('No log file found');
      return null;
    } catch (e) {
      _log.warning('Failed to read log file', e);
      return null;
    }
  }

  Future<String?> _readWebViewLogFile({
    GithubCredentialSnapshot? authorization,
  }) async {
    try {
      final logFile = File('${await AppDirectories.logs}/webview_console.log');
      if (await logFile.exists()) {
        return _scrubSensitive(
          await logFile.readAsString(),
          authorization: authorization,
        );
      }
      _log.info('No webview log file found');
      return null;
    } catch (e) {
      _log.warning('Failed to read webview log file', e);
      return null;
    }
  }

  String _scrubSensitive(
    String content, {
    GithubCredentialSnapshot? authorization,
  }) {
    final sensitive = <String>[
      ..._currentSerialNumbers(),
      _githubToken,
      if (authorization?.authorizationHeader case final header?
          when header.startsWith('Bearer '))
        header.substring('Bearer '.length),
      if (_credentials?.current.authorizationHeader case final header?
          when header.startsWith('Bearer '))
        header.substring('Bearer '.length),
    ]..removeWhere((value) => value.isEmpty);
    return Anonymization.scrubString(content, sensitiveStrings: sensitive);
  }

  Future<Uint8List> _scaleImageToMaxSize(
    Uint8List imageBytes,
    int maxBytes,
  ) async {
    if (imageBytes.length <= maxBytes) return imageBytes;

    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final original = frame.image;

    for (double scale = 0.5; scale >= 0.1; scale -= 0.1) {
      final targetWidth = (original.width * scale).round();
      final targetHeight = (original.height * scale).round();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
      );
      canvas.drawImageRect(
        original,
        Rect.fromLTWH(
          0,
          0,
          original.width.toDouble(),
          original.height.toDouble(),
        ),
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final scaled = await picture.toImage(targetWidth, targetHeight);
      final byteData = await scaled.toByteData(format: ui.ImageByteFormat.png);

      if (byteData == null) continue;
      final result = byteData.buffer.asUint8List();

      _log.fine(
        'Scaled image to ${targetWidth}x$targetHeight: '
        '${result.length} bytes (target: $maxBytes)',
      );

      if (result.length <= maxBytes) return result;
    }

    _log.warning('Could not scale image below $maxBytes bytes');
    return imageBytes;
  }

  String _buildIssueTitle(
    FeedbackRequest request, {
    required GithubCredentialSnapshot authorization,
  }) {
    final prefix = '[${request.type.displayName}]';
    final firstLine = _scrubSensitive(
      request.description,
      authorization: authorization,
    ).split('\n').first;
    final title = firstLine.length > 80
        ? '${firstLine.substring(0, 77)}...'
        : firstLine;
    return '$prefix $title';
  }

  String _buildIssueBody({
    required FeedbackRequest request,
    required String systemInfo,
    String? gistUrl,
    required GithubCredentialSnapshot authorization,
  }) {
    final body = StringBuffer();

    body.writeln('## Description');
    body.writeln(
      _scrubSensitive(request.description, authorization: authorization),
    );
    body.writeln();

    if (systemInfo.isNotEmpty) {
      body.writeln('## System Info');
      body.writeln(systemInfo);
      body.writeln();
    }

    if (gistUrl != null) {
      body.writeln('## Attachments');
      body.writeln('Logs and screenshots: $gistUrl');
      body.writeln();
    }

    body.writeln('---');
    body.writeln(
      '_Submitted via in-app feedback on ${request.timestamp.toIso8601String()}_',
    );

    return body.toString();
  }

  List<String> _buildLabels(FeedbackRequest request) {
    return ['user-feedback', request.type.issueLabel];
  }

  Future<Map<String, dynamic>?> _createGitHubIssue({
    required String title,
    required String body,
    required List<String> labels,
    required GithubCredentialSnapshot authorization,
  }) async {
    try {
      final response = await _sendJson(
        method: 'POST',
        uri: Uri.parse('$_githubApiBase/repos/$_repo/issues'),
        authorization: authorization,
        body: {'title': title, 'body': body, 'labels': labels},
      );

      if (response.statusCode == 201) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        if (authorization.isUser &&
            const [401, 403, 404].contains(response.statusCode)) {
          throw GithubRequestException(
            'GitHub rejected the configured credential. Open Advanced Settings to replace or remove it.',
            statusCode: response.statusCode,
            credentialRejected: true,
          );
        }
        throw remoteHttpError(response.statusCode);
      }
    } catch (_) {
      _log.severe('Failed to create GitHub issue');
      rethrow;
    }
  }

  Future<bool> _linkFeedbackToSupport({
    required int issueNumber,
    required String issueUrl,
    required GithubCredentialSnapshot authorization,
    required Completer<void> abort,
  }) async {
    final accountService = _accountService;
    if (accountService == null || abort.isCompleted) return false;
    if (!await accountService.hasLinkedAccount() || abort.isCompleted) {
      return false;
    }
    final receipt = await accountService.sendSupportMessage(
      subject: 'Decaid feedback #$issueNumber',
      body:
          'Hi,\n\n'
          'I recently submitted feedback from Decaid: $issueUrl\n\n'
          'This message was sent automatically by Decaid for reference and '
          'to keep the feedback linked to my support history.',
      abortTrigger: abort.future,
    );
    final messageId = receipt.messageId;
    if (abort.isCompleted || messageId == null) return false;
    await _appendSupportMessageId(issueNumber, messageId, authorization, abort);
    return !abort.isCompleted;
  }

  Future<void> _appendSupportMessageId(
    int issueNumber,
    String messageId,
    GithubCredentialSnapshot authorization,
    Completer<void> abort,
  ) async {
    final uri = Uri.parse('$_githubApiBase/repos/$_repo/issues/$issueNumber');
    final currentRequest =
        http.AbortableRequest('GET', uri, abortTrigger: abort.future)
          ..headers.addAll(_githubHeaders(uri, authorization))
          ..followRedirects = false;
    final currentResponse = await http.Response.fromStream(
      await _send(currentRequest),
    );
    if (currentResponse.statusCode != 200) {
      throw _SupportReferenceException(
        authorization.isUser &&
                const [401, 403, 404].contains(currentResponse.statusCode)
            ? 'Feedback was created, but GitHub rejected the configured credential. Open Advanced Settings to replace or remove it.'
            : 'Feedback was created, but Decent Support linking could not read the issue. Check GitHub Issues permission; the issue is available on GitHub.',
      );
    }
    if (abort.isCompleted) return;
    final currentBody = _scrubSensitive(
      (jsonDecode(currentResponse.body) as Map<String, dynamic>)['body']
              as String? ??
          '',
      authorization: authorization,
    );
    final separator = currentBody.isEmpty
        ? ''
        : currentBody.endsWith('\n')
        ? '\n'
        : '\n\n';
    final request =
        http.AbortableRequest('PATCH', uri, abortTrigger: abort.future)
          ..headers.addAll(_githubHeaders(uri, authorization, json: true))
          ..followRedirects = false
          ..body = jsonEncode({
            'body':
                '$currentBody$separator---\n**Support message:** `$messageId`\n',
          });
    final response = await http.Response.fromStream(await _send(request));
    if (response.statusCode != 200) {
      throw _SupportReferenceException(
        authorization.isUser &&
                const [401, 403, 404].contains(response.statusCode)
            ? 'Feedback was created, but GitHub rejected the configured credential. Open Advanced Settings to replace or remove it.'
            : 'Feedback was created, but Decent Support linking could not update the issue. Check GitHub Issues permission; the issue is available on GitHub.',
      );
    }
  }

  Future<String> generateHtmlReport(FeedbackRequest request) async {
    final authorization = await _feedbackSnapshot();
    final systemInfo = request.includeSystemInfo ? _collectSystemInfo() : '';
    String? logContent;
    String? webViewLogContent;
    if (request.includeLogs) {
      logContent = await _readLogFile(authorization: authorization);
      webViewLogContent = await _readWebViewLogFile(
        authorization: authorization,
      );
    }

    final html = StringBuffer();
    html.writeln('<!DOCTYPE html>');
    html.writeln('<html><head>');
    html.writeln(
      '<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">',
    );
    html.writeln(
      '<title>[${request.type.displayName}] Feedback Report</title>',
    );
    html.writeln('<style>');
    html.writeln(
      'body{font-family:system-ui,sans-serif;max-width:800px;margin:0 auto;padding:20px;color:#222;background:#fafafa}',
    );
    html.writeln(
      'h1{border-bottom:2px solid #4a7;padding-bottom:8px}h2{color:#555;margin-top:24px}',
    );
    html.writeln(
      'pre{background:#f0f0f0;padding:12px;border-radius:6px;overflow-x:auto;font-size:12px;max-height:600px;overflow-y:auto}',
    );
    html.writeln(
      'img{max-width:100%;border:1px solid #ddd;border-radius:6px;margin:8px 0}',
    );
    html.writeln(
      '.meta{color:#888;font-size:13px;border-top:1px solid #ddd;padding-top:12px;margin-top:24px}',
    );
    html.writeln('ul{line-height:1.8}');
    html.writeln('</style></head><body>');

    html.writeln(
      '<h1>[${_escapeHtml(request.type.displayName)}] Feedback Report</h1>',
    );

    html.writeln('<h2>Description</h2>');
    html.writeln(
      '<p>${_escapeHtml(_scrubSensitive(request.description, authorization: authorization)).replaceAll('\n', '<br>')}</p>',
    );

    if (systemInfo.isNotEmpty) {
      html.writeln('<h2>System Information</h2><ul>');
      for (final line in systemInfo.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('- ')) {
          html.writeln('<li>${_escapeHtml(trimmed.substring(2))}</li>');
        }
      }
      html.writeln('</ul>');
    }

    if (request.screenshots.isNotEmpty) {
      html.writeln('<h2>Screenshots</h2>');
      for (int i = 0; i < request.screenshots.length; i++) {
        final b64 = base64Encode(request.screenshots[i]);
        html.writeln(
          '<p>Screenshot ${i + 1}:</p>'
          '<img src="data:image/png;base64,$b64" alt="Screenshot ${i + 1}">',
        );
      }
    }

    if (logContent != null && logContent.isNotEmpty) {
      const maxLogSize = 100000;
      if (logContent.length > maxLogSize) {
        logContent =
            '... (truncated, showing last ${maxLogSize ~/ 1024}KB) ...\n'
            '${logContent.substring(logContent.length - maxLogSize)}';
      }
      html.writeln('<h2>Application Logs</h2>');
      html.writeln('<pre>${_escapeHtml(logContent)}</pre>');
    }

    if (webViewLogContent != null && webViewLogContent.isNotEmpty) {
      const maxWebViewLogSize = 100000;
      if (webViewLogContent.length > maxWebViewLogSize) {
        webViewLogContent =
            '... (truncated, showing last ${maxWebViewLogSize ~/ 1024}KB) ...\n'
            '${webViewLogContent.substring(webViewLogContent.length - maxWebViewLogSize)}';
      }
      html.writeln('<h2>WebView Console Logs</h2>');
      html.writeln('<pre>${_escapeHtml(webViewLogContent)}</pre>');
    }

    html.writeln(
      '<p class="meta">Generated via Streamline in-app feedback on '
      '${request.timestamp.toIso8601String()}</p>',
    );
    html.writeln('</body></html>');

    return html.toString();
  }

  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }
}

List<String> _noComponents() => const [];
