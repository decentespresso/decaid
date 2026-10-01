import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/backup_import_response.dart';

void main() {
  test('200 parses as a complete import', () {
    final response = BackupImportResponse.fromHttp(
      200,
      '{"profiles":{"imported":4,"skipped":1}}',
    );

    expect(response.status, BackupImportStatus.complete);
    expect(response.sections['profiles']['imported'], 4);
  });

  test('207 parses as a partial import', () {
    final response = BackupImportResponse.fromHttp(
      207,
      '{"profiles":{"imported":4},"shots":{"errors":["bad row"]}}',
    );

    expect(response.status, BackupImportStatus.partial);
    expect(response.sections['profiles']['imported'], 4);
    expect(response.sections['shots']['errors'], contains('bad row'));
  });

  test('207 with only failed sections does not claim partial completion', () {
    final response = BackupImportResponse.fromHttp(
      207,
      '{"profiles":{"status":"failed","errors":["bad row"]}}',
    );

    expect(response.status, BackupImportStatus.failed);
    expect(
      backupImportDialogTitle(response.status),
      'Import Completed with Errors',
    );
  });

  test('partial UI state does not use complete-success wording', () {
    expect(
      backupImportDialogTitle(BackupImportStatus.partial),
      'Import Partially Complete',
    );
    expect(
      backupImportDialogTitle(BackupImportStatus.partial),
      isNot('Import Complete'),
    );
  });

  test(
    'partial results preserve counts and per-section errors for import UI',
    () {
      final response = BackupImportResponse.fromHttp(
        207,
        '{"profiles":{"imported":1,"skipped":2},"shots":{"errors":["bad row"]}}',
      );
      final result = response.toImportResult();

      expect(response.status, BackupImportStatus.partial);
      expect(response.shouldNotifyShotsChanged, isTrue);
      expect(result.profilesImported, 1);
      expect(result.profilesSkipped, 2);
      expect(result.errors.single.filename, 'shots');
      expect(result.errors.single.reason, 'bad row');
    },
  );

  test('400 preserves the server message and string rejection reason', () {
    try {
      BackupImportResponse.fromHttp(
        400,
        '{"error":"Invalid backup archive","message":"No recognized data sections.","reason":"too_many_entries"}',
      );
      fail('Expected BackupImportException');
    } on BackupImportException catch (error) {
      expect(error.isInvalidBackup, isTrue);
      expect(error.message, 'No recognized data sections.');
      expect(error.reason, 'too_many_entries');
    }
  });

  test('only too_many_entries provides conditional De1App guidance', () {
    const guidance =
        'The selected file does not appear to be a normal Decaid backup. '
        'If it is De1App data, extract the archive, use Import from De1App, '
        'and select the de1plus folder.';

    expect(
      const BackupImportException(
        'original',
        reason: 'too_many_entries',
      ).userMessage,
      guidance,
    );
    expect(
      const BackupImportException('original', reason: 'other').userMessage,
      'original',
    );
    expect(const BackupImportException('original').userMessage, 'original');
  });

  test(
    'non-string and missing reasons are ignored and message fallback is unchanged',
    () {
      for (final body in [
        '{"message":"specific message","reason":42}',
        '{"message":"specific message"}',
      ]) {
        try {
          BackupImportResponse.fromHttp(400, body);
          fail('Expected BackupImportException');
        } on BackupImportException catch (error) {
          expect(error.reason, isNull);
          expect(error.userMessage, 'specific message');
        }
      }

      for (final body in ['not json', '[]', 'null']) {
        expect(
          () => BackupImportResponse.fromHttp(400, body),
          throwsA(
            isA<BackupImportException>().having(
              (error) => error.message,
              'message',
              body == 'not json'
                  ? 'The server returned an invalid response.'
                  : 'The server returned status 400.',
            ),
          ),
        );
      }
    },
  );

  test('archive-level failure has no refresh response', () {
    var refreshed = false;
    try {
      BackupImportResponse.fromHttp(
        400,
        '{"message":"Invalid backup archive"}',
      );
      refreshed = true;
    } on BackupImportException {
      refreshed = false;
    }

    expect(refreshed, isFalse);
  });
}
