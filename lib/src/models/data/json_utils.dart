/// Utility functions for JSON manipulation
library;

/// Deep merges two JSON objects.
///
/// Values from [updates] will override values in [base].
/// For nested maps, the merge is recursive.
/// For all other types (lists, primitives, null), [updates] values replace [base] values.
///
/// Example:
/// ```dart
/// final base = {'a': 1, 'b': {'c': 2, 'd': 3}};
/// final updates = {'b': {'d': 4}};
/// final result = deepMergeJson(base, updates);
/// // result: {'a': 1, 'b': {'c': 2, 'd': 4}}
/// ```
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
      // Otherwise, update value replaces base value
      result[key] = updateValue;
    }
  }

  return result;
}
