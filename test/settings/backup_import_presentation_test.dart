import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/backup_import_presentation.dart';
import 'package:reaprime/src/settings/backup_import_response.dart';

void main() {
  for (final (reason, expected, duration) in [
    (
      'too_many_entries',
      'select the de1plus folder',
      const Duration(seconds: 12),
    ),
    ('invalid_zip', 'Could not read backup ZIP', const Duration(seconds: 4)),
  ]) {
    testWidgets('backup import presents $reason error', (tester) async {
      final error = BackupImportException(
        'Could not read backup ZIP',
        reason: reason,
      );
      final snackBar = backupImportErrorSnackBar(error);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    ScaffoldMessenger.of(context).showSnackBar(snackBar),
                child: const Text('Show error'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show error'));
      await tester.pump();
      expect(find.textContaining(expected), findsOneWidget);
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration, duration);
    });
  }
}
