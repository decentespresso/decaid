library;

Map<String, dynamic> deepMergeJson(
  Map<String, dynamic> base,
  Map<String, dynamic> updates,
) {
  final result = Map<String, dynamic>.from(base);

  for (final entry in updates.entries) {
    final key = entry.key;
    final updateValue = entry.value;

    if (!result.containsKey(key)) {
      result[key] = updateValue;
      continue;
    }

    final baseValue = result[key];

    if (baseValue is Map<String, dynamic> &&
        updateValue is Map<String, dynamic>) {
      result[key] = deepMergeJson(baseValue, updateValue);
    } else {
      result[key] = updateValue;
    }
  }

  return result;
}
