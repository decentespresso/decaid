import 'package:reaprime/src/util/remote_error.dart';

enum RemoteUpdateStatus { updated, alreadyCurrent, failed, pendingApproval }

class RemoteUpdateItemResult {
  const RemoteUpdateItemResult({
    required this.item,
    required this.status,
    this.error,
  });

  final String item;
  final RemoteUpdateStatus status;
  final Object? error;

  bool get isFailure => status == RemoteUpdateStatus.failed;

  Map<String, dynamic> toJson() => {
    'item': item,
    'status': status.name,
    if (isFailure) 'error': remoteErrorReason(error!),
  };
}

class RemoteUpdateReport {
  const RemoteUpdateReport(this.results);

  final List<RemoteUpdateItemResult> results;

  bool get hasFailures => results.any((r) => r.isFailure);

  List<({String item, Object error})> get failures => [
    for (final r in results)
      if (r.isFailure) (item: r.item, error: r.error as Object),
  ];

  Map<String, dynamic> toJson() => {
    'results': [for (final r in results) r.toJson()],
  };
}
