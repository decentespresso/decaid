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

      grinders.add(
        Grinder.create(
          model: model,
          burrs: specs['burrs']?.toString(),
          settingType: specs['setting_type']?.toString() == 'numeric'
              ? GrinderSettingType.numeric
              : GrinderSettingType.preset,
          settingSmallStep: double.tryParse(
            specs['small_step']?.toString() ?? '',
          ),
          settingBigStep: double.tryParse(specs['big_step']?.toString() ?? ''),
        ),
      );
    }

    return grinders;
  }
}
