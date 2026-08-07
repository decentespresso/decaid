import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'json_response.dart';

/// REST API handler for submitting user feedback as GitHub issues
class FeedbackHandler {
  final Logger _log = Logger('FeedbackHandler');
  final FeedbackService _service;

  FeedbackHandler({required FeedbackService service}) : _service = service;

  void addRoutes(RouterPlus app) {
    app.post('/api/v1/feedback', _handleSubmitFeedback);
  }

  /// POST /api/v1/feedback
  /// Body: { description: string, type: string, includeLogs?: bool, includeSystemInfo?: bool }
  Future<Response> _handleSubmitFeedback(Request request) async {
    try {
      if (!_service.isConfigured) {
        return jsonServiceUnavailable({
          'error': 'Service unavailable',
          'message':
              'Feedback service is not configured. Build with --dart-define=GITHUB_FEEDBACK_TOKEN=<token>',
        });
      }

      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      if (!json.containsKey('description') ||
          (json['description'] as String).trim().isEmpty) {
        return jsonBadRequest({
          'error': 'Missing required field',
          'message': 'Request must contain a non-empty "description" field',
        });
      }

      final feedbackRequest = FeedbackRequest.fromJson(json);
      final result = await _service.submitFeedback(feedbackRequest);

      if (result.success) {
        return jsonCreated(result.toJson());
      } else {
        return jsonError(result.toJson());
      }
    } catch (e, st) {
      _log.severe('Error in _handleSubmitFeedback', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }
}
