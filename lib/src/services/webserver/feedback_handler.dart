import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/models/feedback/feedback_result.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:reaprime/src/services/webserver/bounded_request_body.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'json_response.dart';

class FeedbackHandler {
  final Logger _log = Logger('FeedbackHandler');
  final FeedbackService _service;

  FeedbackHandler({required this._service});

  void addRoutes(RouterPlus app) {
    app.post('/api/v1/feedback', _handleSubmitFeedback);
  }

  Future<Response> _handleSubmitFeedback(Request request) async {
    try {
      final body = await readBoundedRequestBodyString(
        request,
        maxBytes: largeRequestBodyBytes,
      );
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

      if (result.failureReason == FeedbackFailureReason.accountRequired) {
        return jsonBadRequest({
          'success': false,
          'error': 'Decent account required',
          'message': result.errorMessage,
        });
      } else if (result.success) {
        return result.supportLink == 'failed'
            ? jsonOk(result.toJson())
            : jsonCreated(result.toJson());
      } else if (!_service.isConfigured) {
        return jsonServiceUnavailable({
          'error': 'Service unavailable',
          'message': 'Feedback service is not configured. Open native Advanced Settings to add a GitHub token or build with --dart-define=GITHUB_FEEDBACK_TOKEN=<token>.',
        });
      } else {
        return jsonError(result.toJson());
      }
    } on RequestBodyReadException {
      rethrow;
    } catch (_) {
      _log.severe('Error in _handleSubmitFeedback');
      return jsonError({
        'error': 'Internal server error',
        'message':
            'Could not submit feedback. Check the request and try again.',
      });
    }
  }
}
