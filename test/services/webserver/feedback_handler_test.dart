import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/models/feedback/feedback_result.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:reaprime/src/services/webserver/feedback_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

class _StubFeedbackService implements FeedbackService {
  @override
  final bool isConfigured;
  final FeedbackSubmissionResult Function(FeedbackRequest)? onSubmitted;

  _StubFeedbackService({this.isConfigured = true, this.onSubmitted});

  @override
  Future<FeedbackSubmissionResult> submitFeedback(
    FeedbackRequest request,
  ) async {
    if (onSubmitted != null) return onSubmitted!(request);
    return FeedbackSubmissionResult.succeeded(
      issueUrl: 'https://github.com/decentespresso/decaid/issues/999',
      issueNumber: 999,
    );
  }

  @override
  Future<String> generateHtmlReport(FeedbackRequest request) async {
    return '<html></html>';
  }
}

void main() {
  late Handler handler;
  late _StubFeedbackService service;

  Future<void> wireWith({
    bool isConfigured = true,
    FeedbackSubmissionResult Function(FeedbackRequest)? onSubmitted,
  }) async {
    service = _StubFeedbackService(
      isConfigured: isConfigured,
      onSubmitted: onSubmitted,
    );
    final feedbackHandler = FeedbackHandler(service: service);
    final app = Router().plus;
    feedbackHandler.addRoutes(app);
    handler = app.call;
  }

  Future<Response> post(String path, Object body) async => await handler(
    Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    ),
  );

  group('POST /api/v1/feedback', () {
    test('returns 201 with issue URL and number on success', () async {
      await wireWith();
      final res = await post('/api/v1/feedback', {
        'description': 'Test bug report',
        'type': 'bug',
      });

      expect(res.statusCode, 201);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['success'], true);
      expect(
        body['issueUrl'],
        'https://github.com/decentespresso/decaid/issues/999',
      );
      expect(body['issueNumber'], 999);
    });

    test('returns 400 when description is missing', () async {
      await wireWith();
      final res = await post('/api/v1/feedback', {'type': 'bug'});

      expect(res.statusCode, 400);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'Missing required field');
    });

    test('returns 400 when description is empty', () async {
      await wireWith();
      final res = await post('/api/v1/feedback', {
        'description': '   ',
        'type': 'bug',
      });

      expect(res.statusCode, 400);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'Missing required field');
    });

    test('returns 503 when service is not configured', () async {
      await wireWith(isConfigured: false);
      final res = await post('/api/v1/feedback', {
        'description': 'Test bug report',
        'type': 'bug',
      });

      expect(res.statusCode, 503);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'Service unavailable');
    });

    test('returns 500 when submission fails', () async {
      await wireWith(
        onSubmitted: (_) {
          return FeedbackSubmissionResult.failed('GitHub API error');
        },
      );
      final res = await post('/api/v1/feedback', {
        'description': 'Test bug report',
        'type': 'bug',
      });

      expect(res.statusCode, 500);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['success'], false);
      expect(body['errorMessage'], 'GitHub API error');
    });
  });
}
