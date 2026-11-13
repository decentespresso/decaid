enum FeedbackFailureReason { accountRequired }

class FeedbackSubmissionResult {
  final bool success;
  final String? issueUrl;
  final String? errorMessage;
  final int? issueNumber;
  final String? supportLink;
  final String? warning;
  final FeedbackFailureReason? failureReason;

  const FeedbackSubmissionResult({
    required this.success,
    this.issueUrl,
    this.errorMessage,
    this.issueNumber,
    this.supportLink,
    this.warning,
    this.failureReason,
  });

  factory FeedbackSubmissionResult.succeeded({
    required String issueUrl,
    required int issueNumber,
    String? supportLink,
    String? warning,
  }) {
    return FeedbackSubmissionResult(
      success: true,
      issueUrl: issueUrl,
      issueNumber: issueNumber,
      supportLink: supportLink,
      warning: warning,
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
    if (supportLink != null) 'supportLink': supportLink,
    if (warning != null) 'warning': warning,
  };
}
