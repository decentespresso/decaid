void rejectExplicitNulls(
  Map<String, dynamic> patch,
  Iterable<String> nonNullableFields,
) {
  for (final field in nonNullableFields) {
    if (patch.containsKey(field) && patch[field] == null) {
      throw FormatException('Field "$field" cannot be null');
    }
  }
}
