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
import 'package:reaprime/src/services/storage/app_directories.dart';
import 'package:reaprime/src/services/telemetry/anonymization.dart';

class FeedbackService {
  final String _githubToken;
  final String _repo;
  final List<String> Function() _currentSerialNumbers;
  final DecentAccountService? _accountService;
  final Duration _supportLinkTimeout;
  final Logger _log = Logger('FeedbackService');

  static const String _githubApiBase = 'https://api.github.com';

  FeedbackService({
    required String githubToken,
    String repo = 'decentespresso/decaid',
    required List<String> Function() currentSerialNumbers,
    DecentAccountService? accountService,
    Duration supportLinkTimeout = const Duration(seconds: 30),
  }) : _githubToken = githubToken,
       _repo = repo,
       _currentSerialNumbers = currentSerialNumbers,
       _accountService = accountService,
       _supportLinkTimeout = supportLinkTimeout;

  bool get isConfigured => _githubToken.isNotEmpty;

  Future<FeedbackSubmissionResult> submitFeedback(
    FeedbackRequest request,
  ) async {
    if (!isConfigured) {
      return FeedbackSubmissionResult.failed(
        'Feedback service is not configured. No GitHub token provided at build time.',
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
        );
      }

      final body = _buildIssueBody(
        request: request,
        systemInfo: systemInfo,
        gistUrl: gistUrl,
      );

      final issueResult = await _createGitHubIssue(
        title: _buildIssueTitle(request),
        body: body,
        labels: _buildLabels(request),
      );

      if (issueResult == null) {
        return FeedbackSubmissionResult.failed('Failed to create GitHub issue');
      }

      final issueNumber = issueResult['number'] as int;
      final issueUrl = issueResult['html_url'] as String;

      final supportLinkAbort = Completer<void>();
      try {
        await _linkFeedbackToSupport(
          issueNumber: issueNumber,
          issueUrl: issueUrl,
          abort: supportLinkAbort,
        ).timeout(
          _supportLinkTimeout,
          onTimeout: () {
            supportLinkAbort.complete();
            throw TimeoutException('Decent Support linking timed out');
          },
        );
      } catch (e, st) {
        _log.warning('Could not link feedback to Decent support', e, st);
      }

      _log.info('Feedback submitted successfully as issue #$issueNumber');
      return FeedbackSubmissionResult.succeeded(
        issueUrl: issueUrl,
        issueNumber: issueNumber,
      );
    } catch (e, st) {
      _log.severe('Failed to submit feedback', e, st);
      return FeedbackSubmissionResult.failed('Failed to submit feedback: $e');
    }
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
    return info.toString();
  }

  Future<String?> _uploadGist({
    required bool includeLogs,
    required List<Uint8List> screenshots,
  }) async {
    try {
      final Map<String, Map<String, String>> gistFiles = {};

      if (includeLogs) {
        String? logContent = await _readLogFile();
        if (logContent != null && logContent.isNotEmpty) {
          const maxLogSize = 500000;
          if (logContent.length > maxLogSize) {
            logContent =
                '... (truncated, showing last ${maxLogSize ~/ 1024}KB) ...\n${logContent.substring(logContent.length - maxLogSize)}';
          }
          gistFiles['decent_logs.txt'] = {'content': logContent};
        }

        String? webViewLogContent = await _readWebViewLogFile();
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

      final response = await http.post(
        Uri.parse('$_githubApiBase/gists'),
        headers: _authHeaders,
        body: jsonEncode({
          'description':
              'Decent feedback - ${DateTime.now().toIso8601String()}',
          'public': false,
          'files': gistFiles,
        }),
      );

      if (response.statusCode == 201) {
        final gistData = jsonDecode(response.body) as Map<String, dynamic>;
        final gistUrl = gistData['html_url'] as String;
        _log.info('Gist uploaded: $gistUrl');
        return gistUrl;
      } else {
        _log.warning(
          'Failed to create Gist: ${response.statusCode} - ${response.body}',
        );
        return null;
      }
    } catch (e) {
      _log.warning('Failed to upload Gist', e);
      return null;
    }
  }

  Future<String?> _readLogFile() async {
    try {
      final logFile = File('${await AppDirectories.logs}/log.txt');
      if (await logFile.exists()) {
        return _scrubSensitive(await logFile.readAsString());
      }
      _log.info('No log file found');
      return null;
    } catch (e) {
      _log.warning('Failed to read log file', e);
      return null;
    }
  }

  Future<String?> _readWebViewLogFile() async {
    try {
      final logFile = File('${await AppDirectories.logs}/webview_console.log');
      if (await logFile.exists()) {
        return _scrubSensitive(await logFile.readAsString());
      }
      _log.info('No webview log file found');
      return null;
    } catch (e) {
      _log.warning('Failed to read webview log file', e);
      return null;
    }
  }

  String _scrubSensitive(String content) {
    return Anonymization.scrubString(
      content,
      sensitiveStrings: _currentSerialNumbers(),
    );
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

  String _buildIssueTitle(FeedbackRequest request) {
    final prefix = '[${request.type.displayName}]';
    final firstLine = request.description.split('\n').first;
    final title = firstLine.length > 80
        ? '${firstLine.substring(0, 77)}...'
        : firstLine;
    return '$prefix $title';
  }

  String _buildIssueBody({
    required FeedbackRequest request,
    required String systemInfo,
    String? gistUrl,
  }) {
    final body = StringBuffer();

    body.writeln('## Description');
    body.writeln(request.description);
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
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_githubApiBase/repos/$_repo/issues'),
        headers: _authHeaders,
        body: jsonEncode({'title': title, 'body': body, 'labels': labels}),
      );

      if (response.statusCode == 201) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        _log.severe(
          'Failed to create issue: ${response.statusCode} - ${response.body}',
        );
        return null;
      }
    } catch (e) {
      _log.severe('Failed to create GitHub issue', e);
      return null;
    }
  }

  Future<void> _linkFeedbackToSupport({
    required int issueNumber,
    required String issueUrl,
    required Completer<void> abort,
  }) async {
    final accountService = _accountService;
    if (accountService == null || abort.isCompleted) return;
    if (!await accountService.hasLinkedAccount() || abort.isCompleted) {
      return;
    }
    final contactId = await accountService.sendSupportMessage(
      subject: 'Decaid feedback #$issueNumber',
      body: issueUrl,
      abortTrigger: abort.future,
    );
    if (abort.isCompleted) return;
    await _updateGitHubIssueBody(issueNumber, contactId, abort);
  }

  Future<void> _updateGitHubIssueBody(
    int issueNumber,
    String contactId,
    Completer<void> abort,
  ) async {
    final uri = Uri.parse('$_githubApiBase/repos/$_repo/issues/$issueNumber');
    final currentRequest = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: abort.future,
    )..headers.addAll(_authHeaders);
    final currentResponse = await http.Response.fromStream(
      await currentRequest.send(),
    );
    if (currentResponse.statusCode != 200) {
      throw Exception(
        'Failed to read GitHub issue #$issueNumber '
        '(${currentResponse.statusCode})',
      );
    }
    if (abort.isCompleted) return;
    final currentBody =
        (jsonDecode(currentResponse.body) as Map<String, dynamic>)['body']
            as String? ??
        '';
    final separator = currentBody.isEmpty
        ? ''
        : currentBody.endsWith('\n')
        ? '\n'
        : '\n\n';
    final request =
        http.AbortableRequest('PATCH', uri, abortTrigger: abort.future)
          ..headers.addAll(_authHeaders)
          ..body = jsonEncode({
            'body': '$currentBody$separator---\n**Contact:** `$contactId`\n',
          });
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to update GitHub issue #$issueNumber (${response.statusCode})',
      );
    }
  }

  Future<String> generateHtmlReport(FeedbackRequest request) async {
    final systemInfo = request.includeSystemInfo ? _collectSystemInfo() : '';
    String? logContent;
    String? webViewLogContent;
    if (request.includeLogs) {
      logContent = await _readLogFile();
      webViewLogContent = await _readWebViewLogFile();
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
      '<p>${_escapeHtml(request.description).replaceAll('\n', '<br>')}</p>',
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

  Map<String, String> get _authHeaders => {
    'Authorization': 'token $_githubToken',
    'Accept': 'application/vnd.github.v3+json',
    'Content-Type': 'application/json',
  };
}
