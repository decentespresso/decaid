import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/feedback_controller.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/models/feedback/feedback_result.dart';
import 'package:reaprime/src/services/feedback_service.dart';

class _DeferredFeedback extends Fake implements FeedbackService {
  final completion = Completer<FeedbackSubmissionResult>();
  int calls = 0;

  @override
  Future<FeedbackSubmissionResult> submitFeedback(FeedbackRequest request) {
    calls++;
    return completion.future;
  }
}

void main() {
  final request = FeedbackRequest(
    description: 'Test report',
    type: FeedbackType.bug,
  );

  test('a pending or successful report is not submitted again', () async {
    final service = _DeferredFeedback();
    final controller = FeedbackController(service: service);
    final first = controller.submitFeedback(request);
    await controller.submitFeedback(request);
    service.completion.complete(
      FeedbackSubmissionResult.succeeded(
        issueUrl: 'https://example.test/1',
        issueNumber: 1,
      ),
    );
    final result = await first;
    expect(await controller.submitFeedback(request), same(result));
    expect(service.calls, 1);
    controller.dispose();
  });

  test('completion after disposal does not notify listeners', () async {
    final service = _DeferredFeedback();
    final controller = FeedbackController(service: service);
    final submission = controller.submitFeedback(request);
    controller.dispose();
    service.completion.complete(
      FeedbackSubmissionResult.failed('Connection unavailable'),
    );
    expect((await submission).success, isFalse);
  });
}
