import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

class CapturingJsonSink implements JsonSink {
  final StringBuffer _buffer = StringBuffer();

  @override
  void writeRaw(String fragment) => _buffer.write(fragment);

  String get json => _buffer.toString();
}

class StringJsonInput implements SectionJsonInput {
  final String json;
  final DataTransferLimits limits;

  StringJsonInput(this.json, {this.limits = const DataTransferLimits()});

  @override
  Future<JsonContainerKind> open() async {
    for (final code in json.codeUnits) {
      if (code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D) {
        continue;
      }
      if (code == 0x7B) return JsonContainerKind.object;
      if (code == 0x5B) return JsonContainerKind.array;
      throw const JsonStreamFormatException(
        'The JSON payload must be an object or array.',
      );
    }
    throw const JsonStreamFormatException('The JSON payload is empty.');
  }

  @override
  Stream<JsonValueEvent> valuesAtDepth(
    int depth, {
    void Function(
      int depth,
      List<String> keys,
      JsonContainerKind? containerKind,
    )?
    onValueStart,
  }) async* {
    final parser = IncrementalJsonParser(
      eventDepth: depth,
      maxValueBytes: limits.maxRecordBytes,
      maxKeyBytes: limits.maxKeyBytes,
      maxNestingDepth: limits.maxNestingDepth,
      onValueStart: onValueStart,
    );
    parser.feed(json);
    parser.finish();
    for (final event in parser.drain()) {
      yield event;
    }
  }

  @override
  Future<Object?> readWhole() async {
    Object? value;
    var seen = 0;
    await for (final event in valuesAtDepth(0)) {
      value = event.value;
      seen++;
    }
    if (seen != 1) {
      throw const JsonStreamFormatException(
        'The JSON payload must contain a single value.',
      );
    }
    return value;
  }
}

Future<SectionImportResult> importSectionJson(
  DataExportSection section,
  String json,
  ConflictStrategy strategy, {
  DataTransferLimits limits = const DataTransferLimits(),
}) async {
  final input = StringJsonInput(json, limits: limits);
  return section.importJson(input, strategy);
}
