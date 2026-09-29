enum FeedbackFailureReason { accountRequired }

class FeedbackSubmissionResult {
  final bool success;
  final String? issueUrl;
  final String? errorMessage;
  final int? issueNumber;
  final FeedbackFailureReason? failureReason;

  const FeedbackSubmissionResult({
    required this.success,
    this.issueUrl,
    this.errorMessage,
    this.issueNumber,
    this.failureReason,
  });

  factory FeedbackSubmissionResult.succeeded({
    required String issueUrl,
    required int issueNumber,
  }) {
    return FeedbackSubmissionResult(
      success: true,
      issueUrl: issueUrl,
      issueNumber: issueNumber,
    );
  }

  factory FeedbackSubmissionResult.failed(
    String errorMessage, {
    FeedbackFailureReason? reason,
  }) {
    return FeedbackSubmissionResult(
      success: false,
      errorMessage: errorMessage,
      failureReason: reason,
    );
  }

  Map<String, dynamic> toJson() => {
    'success': success,
    if (issueUrl != null) 'issueUrl': issueUrl,
    if (errorMessage != null) 'errorMessage': errorMessage,
    if (issueNumber != null) 'issueNumber': issueNumber,
  };
}
