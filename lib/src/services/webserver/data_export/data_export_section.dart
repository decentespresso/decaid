import 'dart:convert';

import 'package:reaprime/src/util/incremental_json_parser.dart';

enum ConflictStrategy { skip, overwrite }

class SectionImportResult {
  final int imported;
  final int skipped;
  final List<String> errors;
  final List<String> warnings;

  const SectionImportResult({
    this.imported = 0,
    this.skipped = 0,
    this.errors = const [],
    this.warnings = const [],
  });

  Map<String, dynamic> toJson() => {
    'imported': imported,
    'skipped': skipped,
    if (errors.isNotEmpty) 'errors': errors,
    if (warnings.isNotEmpty) 'warnings': warnings,
  };
}

class SectionImportErrors {
  static const maxRetained = 100;

  final List<String> _retained = [];
  int _omitted = 0;

  void add(String error) {
    if (_retained.length < maxRetained) {
      _retained.add(error);
    } else {
      _omitted++;
    }
  }

  void addAll(Iterable<String> errors) {
    for (final error in errors) {
      add(error);
    }
  }

  List<String> toList() => [
    ..._retained,
    if (_omitted == 1) '1 additional error omitted',
    if (_omitted > 1) '$_omitted additional errors omitted',
  ];
}

abstract class JsonSink {
  void writeRaw(String fragment);
}

abstract class SectionJsonInput {
  Future<JsonContainerKind> open();

  Stream<JsonValueEvent> valuesAtDepth(
    int depth, {
    void Function(
      int depth,
      List<String> keys,
      JsonContainerKind? containerKind,
    )?
    onValueStart,
  });

  Future<Object?> readWhole();
}

class JsonArrayEmitter {
  final JsonSink _sink;
  bool _first = true;

  JsonArrayEmitter(this._sink) {
    _sink.writeRaw('[');
  }

  void add(Object? value) {
    _sink.writeRaw(_first ? '' : ',');
    _sink.writeRaw(jsonEncode(value));
    _first = false;
  }

  void end() => _sink.writeRaw(']');
}

abstract class DataExportSection {
  String get filename;

  Future<void> exportJson(JsonSink output);

  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy,
  );
}
