class RemoteUpdateException implements Exception {
  final int attemptedCount;
  final List<({String item, Object error})> failures;

  RemoteUpdateException({
    required this.attemptedCount,
    required List<({String item, Object error})> failures,
  }) : failures = List.unmodifiable(failures);

  bool get isPartial => failures.length < attemptedCount;

  @override
  String toString() =>
      'RemoteUpdateException: ${failures.length} of $attemptedCount checks failed';
}
