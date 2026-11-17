import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/widgets/import_source_picker.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('displays Decaid import source copy', (tester) async {
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: ImportSourcePicker(
            onDe1appFolderSelected: (_) {},
            onZipFileSelected: (_) {},
          ),
        ),
      ),
    );

    expect(
      find.text('Bring your data from De1App or restore a Decaid backup.'),
      findsOneWidget,
    );
    expect(find.text('Import Decaid backup'), findsOneWidget);
    expect(find.textContaining('Bridge backup'), findsNothing);
    expect(find.text('Import from De1App'), findsOneWidget);
    expect(find.text('Select a .zip backup file'), findsOneWidget);
  });
}
