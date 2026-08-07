import 'dart:typed_data';

enum FeedbackType {
  bug,
  feature,
  question,
  other;

  String get displayName {
    switch (this) {
      case FeedbackType.bug:
        return 'Bug Report';
      case FeedbackType.feature:
        return 'Feature Request';
      case FeedbackType.question:
        return 'Question';
      case FeedbackType.other:
        return 'Other';
    }
  }

  String get issueLabel {
    switch (this) {
      case FeedbackType.bug:
        return 'bug';
      case FeedbackType.feature:
        return 'enhancement';
      case FeedbackType.question:
        return 'question';
      case FeedbackType.other:
        return 'feedback';
    }
  }
}

class FeedbackRequest {
  final String description;
  final FeedbackType type;
  final bool includeLogs;
  final bool includeSystemInfo;
  final List<Uint8List> screenshots;
  final DateTime timestamp;

  FeedbackRequest({
    required this.description,
    required this.type,
    this.includeLogs = true,
    this.includeSystemInfo = true,
    this.screenshots = const [],
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'description': description,
    'type': type.name,
    'includeLogs': includeLogs,
    'includeSystemInfo': includeSystemInfo,
    'screenshotCount': screenshots.length,
    'timestamp': timestamp.toIso8601String(),
  };

  factory FeedbackRequest.fromJson(Map<String, dynamic> json) {
    return FeedbackRequest(
      description: json['description'] as String,
      type: FeedbackType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => FeedbackType.other,
      ),
      includeLogs: json['includeLogs'] as bool? ?? true,
      includeSystemInfo: json['includeSystemInfo'] as bool? ?? true,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
    );
  }
}
