double parseDouble(dynamic value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return double.tryParse(value) ?? int.parse(value).toDouble();
}

double? parseOptionalDouble(dynamic value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return double.tryParse(value) ?? int.tryParse(value)?.toDouble();
}

int parseInt(dynamic value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  return int.parse(value);
}

/// Coerce a JSON value to `String?`, tolerating numeric and boolean
/// inputs (JSON does not require IDs to be strings). Returns null for
/// nulls and for structured values (Map / List) — silently stringifying
/// those would poison the field with noise like `"{a: 1}"`.
String? parseOptionalString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}
