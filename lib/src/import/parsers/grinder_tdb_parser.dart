import 'package:reaprime/src/import/parsers/tcl_parser.dart';
import 'package:reaprime/src/models/data/grinder.dart';

class GrinderTdbParser {
  static List<Grinder> parse(String content) {
    final data = TclParser.parse(content);
    final grinders = <Grinder>[];

    for (final entry in data.entries) {
      final model = entry.key;
      final specs = entry.value;
      if (specs is! Map<String, dynamic>) continue;

      final isNumeric = specs['is_numeric']?.toString() == '1';

      grinders.add(
        Grinder.create(
          model: model,
          settingType: isNumeric
              ? GrinderSettingType.numeric
              : GrinderSettingType.preset,
          settingValues: isNumeric ? null : _stringList(specs['values']),
          settingSmallStep: double.tryParse(
            specs['small_step']?.toString() ?? '',
          ),
          settingBigStep: double.tryParse(specs['big_step']?.toString() ?? ''),
        ),
      );
    }

    return grinders;
  }

  static List<String>? _stringList(dynamic value) {
    final values = switch (value) {
      List() => value.map((v) => v.toString()).toList(),
      Map() => [
        for (final entry in value.entries) ...[
          entry.key.toString(),
          entry.value.toString(),
        ],
      ],
      String() => TclParser.splitList(value),
      _ => const <String>[],
    };
    return values.isEmpty ? null : values;
  }
}
