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

void validatePatchFieldTypes(
  Map<String, dynamic> patch, {
  Iterable<String> numberFields = const [],
  Iterable<String> integerListFields = const [],
  Iterable<String> stringListFields = const [],
}) {
  _validateFields(patch, numberFields, (value) => value is num, 'a number');
  _validateFields(
    patch,
    integerListFields,
    (value) => value is List && value.every((item) => item is int),
    'an array of integers',
  );
  _validateFields(
    patch,
    stringListFields,
    (value) => value is List && value.every((item) => item is String),
    'an array of strings',
  );
}

void _validateFields(
  Map<String, dynamic> patch,
  Iterable<String> fields,
  bool Function(Object value) isValid,
  String expectedType,
) {
  for (final field in fields) {
    final value = patch[field];
    if (!patch.containsKey(field) || value == null) continue;
    if (!isValid(value)) {
      throw FormatException('Field "$field" must be $expectedType or null');
    }
  }
}
