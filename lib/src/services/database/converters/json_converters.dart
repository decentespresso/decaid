import 'dart:convert';

import 'package:drift/drift.dart';

class JsonMapConverter extends TypeConverter<Map<String, dynamic>, String> {
  const JsonMapConverter();

  @override
  Map<String, dynamic> fromSql(String fromDb) {
    return jsonDecode(fromDb) as Map<String, dynamic>;
  }

  @override
  String toSql(Map<String, dynamic> value) {
    return jsonEncode(value);
  }
}

class NullableJsonMapConverter
    extends TypeConverter<Map<String, dynamic>?, String?> {
  const NullableJsonMapConverter();

  @override
  Map<String, dynamic>? fromSql(String? fromDb) {
    if (fromDb == null) return null;
    return jsonDecode(fromDb) as Map<String, dynamic>;
  }

  @override
  String? toSql(Map<String, dynamic>? value) {
    if (value == null) return null;
    return jsonEncode(value);
  }
}

class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) {
    return (jsonDecode(fromDb) as List).cast<String>();
  }

  @override
  String toSql(List<String> value) {
    return jsonEncode(value);
  }
}

class NullableStringListConverter
    extends TypeConverter<List<String>?, String?> {
  const NullableStringListConverter();

  @override
  List<String>? fromSql(String? fromDb) {
    if (fromDb == null) return null;
    return (jsonDecode(fromDb) as List).cast<String>();
  }

  @override
  String? toSql(List<String>? value) {
    if (value == null) return null;
    return jsonEncode(value);
  }
}

class NullableIntListConverter extends TypeConverter<List<int>?, String?> {
  const NullableIntListConverter();

  @override
  List<int>? fromSql(String? fromDb) {
    if (fromDb == null) return null;
    return (jsonDecode(fromDb) as List).cast<int>();
  }

  @override
  String? toSql(List<int>? value) {
    if (value == null) return null;
    return jsonEncode(value);
  }
}
