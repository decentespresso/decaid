import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/models/feedback/feedback_result.dart';
import 'package:reaprime/src/services/feedback_service.dart';

enum FeedbackState { idle, submitting, success, error }

class FeedbackController extends ChangeNotifier {
  final FeedbackService _service;
  final Logger _log = Logger('FeedbackController');

  FeedbackState _state = FeedbackState.idle;
  FeedbackSubmissionResult? _lastResult;

  FeedbackController({required FeedbackService service}) : _service = service;

  FeedbackState get state => _state;

  FeedbackSubmissionResult? get lastResult => _lastResult;

  bool get isConfigured => _service.isConfigured;

  bool get isSubmitting => _state == FeedbackState.submitting;

  Future<FeedbackSubmissionResult> submitFeedback(
    FeedbackRequest request,
  ) async {
    _state = FeedbackState.submitting;
    _lastResult = null;
    notifyListeners();

    _log.info('Submitting feedback: ${request.type.name}');

    final result = await _service.submitFeedback(request);

    _lastResult = result;
    _state = result.success ? FeedbackState.success : FeedbackState.error;
    notifyListeners();

    if (result.success) {
      _log.info('Feedback submitted: issue #${result.issueNumber}');
    } else {
      _log.warning('Feedback submission failed: ${result.errorMessage}');
    }

    return result;
  }

  void reset() {
    _state = FeedbackState.idle;
    _lastResult = null;
    notifyListeners();
  }
}
