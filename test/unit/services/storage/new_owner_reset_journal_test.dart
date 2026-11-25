import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/storage/new_owner_reset_journal.dart';

const _retained = NewOwnerResetRetainedConfiguration(
  preferredMachineId: 'synthetic-machine-a',
  preferredScaleId: 'usb-hds:any',
  skin: RetainedSkinReference(skinId: 'default', packageId: 'bundled:default'),
);

void main() {
  late Directory temp;
  late File journalFile;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('new-owner-reset-journal-');
    journalFile = File('${temp.path}/new-owner-reset-journal.json');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  NewOwnerResetJournalFileStore store() =>
      NewOwnerResetJournalFileStore(journalFile);

  NewOwnerResetJournal open({
    NewOwnerResetJournalStore? backing,
    String session = 'process-1',
  }) => NewOwnerResetJournal(backing ?? store(), processSessionId: session);

  group('missing journal', () {
    test('is an explicit no-reset result and creates nothing', () {
      final journal = open();

      final result = journal.load();

      expect(result, isA<NewOwnerResetJournalAbsent>());
      expect(journal.record, isNull);
      expect(journalFile.existsSync(), isFalse);
    });

    test('cannot acknowledge or consume without an in-progress reset', () {
      final journal = open()..load();

      expect(
        journal.acknowledgeHandoff,
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(
        journal.consumeHandoff,
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(journalFile.existsSync(), isFalse);
    });
  });

  group('stage transitions', () {
    test('resetting walks deletion, restoration and verification', () {
      final journal = open()..load();

      journal.beginReset(retained: _retained);
      expect(journal.record!.state, NewOwnerResetState.resetting);
      expect(journal.record!.stage, NewOwnerResetStage.deletion);
      expect(
        journal.record!.retained.preferredMachineId,
        'synthetic-machine-a',
      );
      expect(journal.record!.retained.preferredScaleId, 'usb-hds:any');
      expect(journal.record!.retained.skin!.packageId, 'bundled:default');

      journal.completeStage(NewOwnerResetStage.deletion);
      expect(journal.record!.state, NewOwnerResetState.resetting);
      expect(journal.record!.stage, NewOwnerResetStage.restoration);

      journal.completeStage(NewOwnerResetStage.restoration);
      expect(journal.record!.stage, NewOwnerResetStage.verification);
    });

    test('verification completion is the only path to ready', () {
      final journal = open()..load();
      journal.beginReset(retained: _retained);

      expect(
        () => journal.acknowledgeHandoff(),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      journal.completeStage(NewOwnerResetStage.deletion);
      journal.completeStage(NewOwnerResetStage.restoration);
      expect(journal.record!.state, NewOwnerResetState.resetting);
      expect(
        () => journal.acknowledgeHandoff(),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );

      journal.completeStage(NewOwnerResetStage.verification);

      expect(journal.record!.state, NewOwnerResetState.ready);
      expect(journal.record!.stage, isNull);
      expect(journal.record!.retained.preferredScaleId, 'usb-hds:any');
      expect(
        journal.record!.retained.preferredMachineId,
        'synthetic-machine-a',
      );
    });

    test('repeating a completed stage is an idempotent no-op', () {
      final journal = open()..load();
      journal.beginReset(retained: _retained);
      journal.completeStage(NewOwnerResetStage.deletion);

      journal.completeStage(NewOwnerResetStage.deletion);

      expect(journal.record!.stage, NewOwnerResetStage.restoration);
    });

    test('repeating every stage after ready is rejected', () {
      final journal = open()..load();
      journal.beginReset(retained: _retained);
      journal.completeStage(NewOwnerResetStage.deletion);
      journal.completeStage(NewOwnerResetStage.restoration);
      journal.completeStage(NewOwnerResetStage.verification);

      expect(
        () => journal.completeStage(NewOwnerResetStage.verification),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(journal.record!.state, NewOwnerResetState.ready);
    });

    test('skipping a stage is rejected without advancing durable state', () {
      final journal = open()..load();
      journal.beginReset(retained: _retained);

      expect(
        () => journal.completeStage(NewOwnerResetStage.verification),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );

      final reloaded = open()..load();
      expect(reloaded.record!.state, NewOwnerResetState.resetting);
      expect(reloaded.record!.stage, NewOwnerResetStage.deletion);
    });

    test('a duplicate begin request never clobbers recovery data', () {
      final journal = open()..load();
      journal.beginReset(retained: _retained);
      journal.completeStage(NewOwnerResetStage.deletion);

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );

      final reloaded = open()..load();
      expect(reloaded.record!.stage, NewOwnerResetStage.restoration);
    });

    test('operations refuse to run before the journal was loaded', () {
      final journal = open();

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(journalFile.existsSync(), isFalse);
    });
  });

  group('isolated file persistence', () {
    test('writes survive a new owner instance and leave no temp file', () {
      final journal = open()..load();
      journal.beginReset(retained: _retained);
      journal.completeStage(NewOwnerResetStage.deletion);

      final reloaded = open()..load();

      expect(reloaded.record!.state, NewOwnerResetState.resetting);
      expect(reloaded.record!.stage, NewOwnerResetStage.restoration);
      expect(reloaded.record!.retained.skin!.skinId, _retained.skin!.skinId);
      expect(File('${journalFile.path}.tmp').existsSync(), isFalse);
    });

    test('an existing journal file is replaced, not appended', () {
      final journal = open()..load();
      journal.beginReset(retained: _retained);
      journal.completeStage(NewOwnerResetStage.deletion);

      final decoded =
          jsonDecode(journalFile.readAsStringSync()) as Map<String, dynamic>;

      expect(decoded['stage'], 'restoration');
      expect((decoded['retained'] as Map<String, dynamic>).keys.toSet(), {
        'preferredMachineId',
        'preferredScaleId',
        'skin',
      });
      expect(
        decoded['retained'],
        containsPair('preferredMachineId', 'synthetic-machine-a'),
      );
      expect(
        decoded['retained'],
        containsPair('preferredScaleId', 'usb-hds:any'),
      );
      expect(
        utf8.decode(journalFile.readAsBytesSync()).trim().startsWith('{'),
        isTrue,
      );
      expect(decoded.keys.toSet(), {
        'schemaVersion',
        'state',
        'stage',
        'retained',
        'armedBySessionId',
      });
    });

    test('a leftover temp file never changes a readable journal', () {
      final journal = open()..load();
      journal.beginReset(retained: _retained);
      File('${journalFile.path}.tmp').writeAsStringSync('garbage');

      final reloaded = open()..load();

      expect(reloaded.record!.state, NewOwnerResetState.resetting);
    });
  });

  group('unreadable journal paths', () {
    test('a missing file is still an explicit no-reset result', () {
      final result = open().load();

      expect(result, isA<NewOwnerResetJournalAbsent>());
    });

    test('a directory at the journal path is unreadable, not absent', () {
      Directory(journalFile.path).createSync();

      final result = open().load();

      expect(result, isA<NewOwnerResetJournalUnreadable>());
      expect(Directory(journalFile.path).existsSync(), isTrue);
      expect(
        () => open().beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
    });

    test(
      'a symlink at the journal path is unreadable and its target untouched',
      () {
        final decoyRaw = jsonEncode(_validResettingMap());
        final decoy = File('${temp.path}/decoy.json')
          ..writeAsStringSync(decoyRaw);
        Link(journalFile.path).createSync(decoy.path);

        final result = open().load();

        expect(result, isA<NewOwnerResetJournalUnreadable>());
        expect(decoy.readAsStringSync(), decoyRaw);
      },
    );

    test('a dangling symlink is unreadable, not absent', () {
      Link(journalFile.path).createSync('${temp.path}/missing-target.json');

      final result = open().load();

      expect(result, isA<NewOwnerResetJournalUnreadable>());
    });

    test(
      'an inaccessible journal path is unreadable, not absent',
      () {
        final locked = Directory('${temp.path}/locked')..createSync();
        final lockedJournal = File('${locked.path}/journal.json')
          ..writeAsStringSync(jsonEncode(_validResettingMap()));
        Process.runSync('chmod', ['000', locked.path]);
        try {
          final journal = NewOwnerResetJournal(
            NewOwnerResetJournalFileStore(lockedJournal),
            processSessionId: 'process-1',
          );

          final result = journal.load();

          expect(result, isA<NewOwnerResetJournalUnreadable>());
          expect(journal.record, isNull);
        } finally {
          Process.runSync('chmod', ['755', locked.path]);
        }
      },
      skip: _mayRestrictPermissions() ? null : 'requires a non-root POSIX user',
    );
  });

  group('failed writes', () {
    test('a failed first write publishes no in-memory or durable state', () {
      final faulty = _FaultyStore(store())..failWrites = true;
      final journal = open(backing: faulty)..load();

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(journal.record, isNull);
      expect(journalFile.existsSync(), isFalse);
    });

    test('a staging fault leaves the previous record published', () {
      final journal = open()..load();
      journal.beginReset(retained: _retained);
      journal.completeStage(NewOwnerResetStage.deletion);
      journal.completeStage(NewOwnerResetStage.restoration);
      journal.completeStage(NewOwnerResetStage.verification);
      final readyRaw = journalFile.readAsStringSync();
      Directory('${journalFile.path}.tmp').createSync();

      expect(
        () => journal.acknowledgeHandoff(),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(journal.record!.state, NewOwnerResetState.ready);
      expect(journalFile.readAsStringSync(), readyRaw);
      final reloaded = open()..load();
      expect(reloaded.record!.state, NewOwnerResetState.ready);
    });

    test('a failed stage write keeps the previous stage durable', () {
      final faulty = _FaultyStore(store());
      final journal = open(backing: faulty)..load();
      journal.beginReset(retained: _retained);
      faulty.failWrites = true;

      expect(
        () => journal.completeStage(NewOwnerResetStage.deletion),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(journal.record!.stage, NewOwnerResetStage.deletion);
      final reloaded = open()..load();
      expect(reloaded.record!.stage, NewOwnerResetStage.deletion);
    });
  });

  group('unsafe journal paths', () {
    test(
      'a symlink at the staging path is rejected without touching its target',
      () {
        final sentinel = File('${temp.path}/unrelated.json')
          ..writeAsStringSync('SENTINEL');
        Link('${journalFile.path}.tmp').createSync(sentinel.path);
        final journal = open()..load();

        expect(
          () => journal.beginReset(retained: _retained),
          throwsA(isA<NewOwnerResetJournalWriteException>()),
        );

        expect(sentinel.readAsStringSync(), 'SENTINEL');
        expect(journal.record, isNull);
        expect(journalFile.existsSync(), isFalse);
        expect(Link('${journalFile.path}.tmp').existsSync(), isTrue);
      },
    );

    test('a directory at the staging path is rejected and left alone', () {
      Directory('${journalFile.path}.tmp').createSync();
      final journal = open()..load();

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(journal.record, isNull);
      expect(Directory('${journalFile.path}.tmp').existsSync(), isTrue);
      expect(journalFile.existsSync(), isFalse);
    });

    test('a canonical path replaced by a symlink after load is rejected', () {
      final sentinel = File('${temp.path}/unrelated.json')
        ..writeAsStringSync('SENTINEL');
      final journal = open()..load();
      Link(journalFile.path).createSync(sentinel.path);

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(sentinel.readAsStringSync(), 'SENTINEL');
      expect(journal.record, isNull);
    });

    test(
      'a canonical directory refuses deletion instead of faking success',
      () {
        final arming = open()..load();
        _driveToReady(arming);
        arming.acknowledgeHandoff();
        final nextProcess = open(session: 'process-2')..load();
        journalFile.deleteSync();
        Directory(journalFile.path).createSync();

        expect(
          () => nextProcess.consumeHandoff(),
          throwsA(isA<NewOwnerResetJournalWriteException>()),
        );

        expect(nextProcess.record!.state, NewOwnerResetState.handoffArmed);
        expect(Directory(journalFile.path).existsSync(), isTrue);
      },
    );

    test('a canonical symlink refuses deletion instead of faking success', () {
      final arming = open()..load();
      _driveToReady(arming);
      arming.acknowledgeHandoff();
      final nextProcess = open(session: 'process-2')..load();
      final decoyRaw = journalFile.readAsStringSync();
      final decoy = File('${temp.path}/decoy.json')
        ..writeAsStringSync(decoyRaw);
      journalFile.deleteSync();
      Link(journalFile.path).createSync(decoy.path);

      expect(
        () => nextProcess.consumeHandoff(),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(nextProcess.record!.state, NewOwnerResetState.handoffArmed);
      expect(Link(journalFile.path).existsSync(), isTrue);
      expect(decoy.readAsStringSync(), decoyRaw);
    });
  });

  group('outbound validation', () {
    test('an invalid retained configuration is never published or written', () {
      for (final invalid in <NewOwnerResetRetainedConfiguration>[
        const NewOwnerResetRetainedConfiguration(preferredMachineId: ''),
        const NewOwnerResetRetainedConfiguration(preferredScaleId: '   '),
        const NewOwnerResetRetainedConfiguration(
          skin: RetainedSkinReference(skinId: '', packageId: 'bundled:default'),
        ),
      ]) {
        final journal = open()..load();

        expect(
          () => journal.beginReset(retained: invalid),
          throwsA(isA<NewOwnerResetJournalWriteException>()),
          reason: 'accepted $invalid',
        );

        expect(journal.record, isNull);
        expect(journalFile.existsSync(), isFalse);
        expect(File('${journalFile.path}.tmp').existsSync(), isFalse);
      }
    });
  });

  group('crash windows around replacement', () {
    test('a staged acknowledgment that never replaced leaves ready', () {
      final journal = open()..load();
      _driveToReady(journal);
      final readyRaw = journalFile.readAsStringSync();
      const staged = NewOwnerResetJournalRecord.handoffArmed(
        retained: _retained,
        armedBySessionId: 'process-1',
      );
      File('${journalFile.path}.tmp')
          .writeAsStringSync(jsonEncode(staged.toJson()));

      final recovered = open(session: 'process-2')..load();

      expect(recovered.record!.state, NewOwnerResetState.ready);
      expect(recovered.record!.armedBySessionId, isNull);
      expect(journalFile.readAsStringSync(), readyRaw);
      expect(File('${journalFile.path}.tmp').existsSync(), isTrue);
      expect(
        () => recovered.consumeHandoff(),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
    });

    test('an acknowledgment committed by rename loads as armed', () {
      final journal = open()..load();
      _driveToReady(journal);
      const staged = NewOwnerResetJournalRecord.handoffArmed(
        retained: _retained,
        armedBySessionId: 'process-1',
      );
      File('${journalFile.path}.tmp')
        ..writeAsStringSync(jsonEncode(staged.toJson()))
        ..renameSync(journalFile.path);

      final nextProcess = open(session: 'process-2')..load();

      expect(nextProcess.record!.state, NewOwnerResetState.handoffArmed);
      expect(nextProcess.record!.armedBySessionId, 'process-1');
      nextProcess.consumeHandoff();
      expect(journalFile.existsSync(), isFalse);
    });
  });

  group('handoff acknowledgment', () {
    test('a ready journal arms the handoff for the current process', () {
      final journal = open()..load();
      _driveToReady(journal);

      journal.acknowledgeHandoff();

      expect(journal.record!.state, NewOwnerResetState.handoffArmed);
      expect(journal.record!.armedBySessionId, 'process-1');
      final reloaded = open()..load();
      expect(reloaded.record!.state, NewOwnerResetState.handoffArmed);
    });

    test('a failed acknowledgment write leaves ready', () {
      final faulty = _FaultyStore(store());
      final journal = open(backing: faulty)..load();
      _driveToReady(journal);
      faulty.failWrites = true;

      expect(
        () => journal.acknowledgeHandoff(),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(journal.record!.state, NewOwnerResetState.ready);
      final reloaded = open()..load();
      expect(reloaded.record!.state, NewOwnerResetState.ready);
    });

    test('a repeated acknowledgment in the same process is rejected', () {
      final journal = open()..load();
      _driveToReady(journal);
      journal.acknowledgeHandoff();

      expect(
        () => journal.acknowledgeHandoff(),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(journal.record!.state, NewOwnerResetState.handoffArmed);
    });
  });

  group('process handoff boundary', () {
    test(
      'the acknowledging process stays terminal, even for a new instance',
      () {
        final arming = open()..load();
        _driveToReady(arming);
        arming.acknowledgeHandoff();

        expect(
          () => arming.consumeHandoff(),
          throwsA(isA<NewOwnerResetJournalStateException>()),
        );

        final rebuiltInSameProcess = open(session: 'process-1')..load();
        expect(
          rebuiltInSameProcess.record!.state,
          NewOwnerResetState.handoffArmed,
        );
        expect(
          () => rebuiltInSameProcess.consumeHandoff(),
          throwsA(isA<NewOwnerResetJournalStateException>()),
        );
        expect(journalFile.existsSync(), isTrue);
      },
    );

    test('a later process consumes the handoff exactly once', () {
      final arming = open()..load();
      _driveToReady(arming);
      arming.acknowledgeHandoff();

      final nextProcess = open(session: 'process-2')..load();
      expect(nextProcess.record!.state, NewOwnerResetState.handoffArmed);

      nextProcess.consumeHandoff();
      expect(nextProcess.record, isNull);
      expect(journalFile.existsSync(), isFalse);

      final thirdProcess = open(session: 'process-3')..load();
      expect(thirdProcess.load(), isA<NewOwnerResetJournalAbsent>());
      expect(
        () => thirdProcess.consumeHandoff(),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
    });

    test('a failed consume keeps the recovery data for the next process', () {
      final arming = open()..load();
      _driveToReady(arming);
      arming.acknowledgeHandoff();
      final faulty = _FaultyStore(store())..failDeletes = true;
      final nextProcess = open(backing: faulty, session: 'process-2')..load();

      expect(
        () => nextProcess.consumeHandoff(),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(nextProcess.record!.state, NewOwnerResetState.handoffArmed);
      expect(journalFile.existsSync(), isTrue);
      final retried = open(session: 'process-3')..load();
      expect(retried.record!.state, NewOwnerResetState.handoffArmed);
      retried.consumeHandoff();
      expect(journalFile.existsSync(), isFalse);
    });

    test(
      'an inaccessible journal path refuses deletion instead of faking success',
      () {
        final locked = Directory('${temp.path}/locked')..createSync();
        final lockedJournal = File('${locked.path}/journal.json');
        final arming = NewOwnerResetJournal(
          NewOwnerResetJournalFileStore(lockedJournal),
          processSessionId: 'process-1',
        )..load();
        _driveToReady(arming);
        arming.acknowledgeHandoff();
        final armedRaw = lockedJournal.readAsStringSync();
        final nextProcess = NewOwnerResetJournal(
          NewOwnerResetJournalFileStore(lockedJournal),
          processSessionId: 'process-2',
        )..load();
        Process.runSync('chmod', ['000', locked.path]);
        try {
          expect(
            () => nextProcess.consumeHandoff(),
            throwsA(isA<NewOwnerResetJournalWriteException>()),
          );

          expect(nextProcess.record!.state, NewOwnerResetState.handoffArmed);
        } finally {
          Process.runSync('chmod', ['755', locked.path]);
        }
        expect(lockedJournal.readAsStringSync(), armedRaw);
      },
      skip: _mayRestrictPermissions() ? null : 'requires a non-root POSIX user',
    );

    test('ready without acknowledgment never hands off', () {
      final ready = open()..load();
      _driveToReady(ready);

      final nextProcess = open(session: 'process-2')..load();

      expect(nextProcess.record!.state, NewOwnerResetState.ready);
      expect(
        () => nextProcess.consumeHandoff(),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(journalFile.existsSync(), isTrue);
    });
  });

  group('strict schema rejection', () {
    test('an unreadable file fails closed and blocks writes', () {
      journalFile.writeAsStringSync('{not json');

      final journal = open();
      final result = journal.load();

      expect(result, isA<NewOwnerResetJournalUnreadable>());
      expect(
        (result as NewOwnerResetJournalUnreadable).reason,
        contains('JSON'),
      );
      expect(journal.record, isNull);
      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
    });

    test('an unknown schema version is rejected', () {
      journalFile.writeAsStringSync(
        jsonEncode({..._validResettingMap(), 'schemaVersion': 2}),
      );

      final result = open().load();

      expect(result, isA<NewOwnerResetJournalUnreadable>());
      expect(
        (result as NewOwnerResetJournalUnreadable).reason,
        contains('version'),
      );
    });

    test('an unknown state or stage is rejected', () {
      journalFile.writeAsStringSync(
        jsonEncode({..._validResettingMap(), 'state': 'onboarding'}),
      );
      expect(open().load(), isA<NewOwnerResetJournalUnreadable>());

      journalFile.writeAsStringSync(
        jsonEncode({..._validResettingMap(), 'stage': 'upload'}),
      );
      expect(open().load(), isA<NewOwnerResetJournalUnreadable>());
    });

    test('arbitrary extra payload is rejected at either level', () {
      journalFile.writeAsStringSync(
        jsonEncode({
          ..._validResettingMap(),
          'userBackup': base64Encode(utf8.encode('secret-shot-data')),
        }),
      );
      final topLevel = open().load();
      expect(topLevel, isA<NewOwnerResetJournalUnreadable>());
      expect(
        (topLevel as NewOwnerResetJournalUnreadable).reason,
        contains('userBackup'),
      );

      journalFile.writeAsStringSync(
        jsonEncode({
          ..._validResettingMap(),
          'retained': {
            'preferredMachineId': 'synthetic-machine-a',
            'preferredScaleId': 'usb-hds:any',
            'skin': null,
            'accountToken': 'abc',
          },
        }),
      );
      final nested = open().load();
      expect(nested, isA<NewOwnerResetJournalUnreadable>());
      expect(
        (nested as NewOwnerResetJournalUnreadable).reason,
        contains('accountToken'),
      );
    });

    test('state invariants are enforced', () {
      for (final invalid in <Map<String, Object?>>[
        {..._validResettingMap(), 'stage': null},
        {..._validResettingMap(), 'state': 'ready'},
        {..._validResettingMap(), 'state': 'handoffArmed'},
        {
          ..._validResettingMap(),
          'state': 'ready',
          'stage': null,
          'armedBySessionId': 'process-1',
        },
        {
          ..._validResettingMap(),
          'state': 'handoffArmed',
          'stage': null,
          'armedBySessionId': '',
        },
        {..._validResettingMap(), 'schemaVersion': '1'},
        {..._validResettingMap(), 'retained': null},
        {
          ..._validResettingMap(),
          'retained': {
            'skin': {'skinId': 'default'},
          },
        },
      ]) {
        journalFile.writeAsStringSync(jsonEncode(invalid));
        expect(
          open().load(),
          isA<NewOwnerResetJournalUnreadable>(),
          reason: 'accepted $invalid',
        );
      }
    });

    test('the persisted journal holds only typed non-secret fields', () {
      final journal = open()..load();
      _driveToReady(journal);
      journal.acknowledgeHandoff();

      expect(journal.record!.state, NewOwnerResetState.handoffArmed);
      final raw = journalFile.readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(decoded.keys.toSet(), {
        'schemaVersion',
        'state',
        'stage',
        'retained',
        'armedBySessionId',
      });
      expect((decoded['retained'] as Map<String, dynamic>).keys.toSet(), {
        'preferredMachineId',
        'preferredScaleId',
        'skin',
      });
      expect(raw, isNot(contains('token')));
      expect(raw, isNot(contains('password')));
    });
  });
}

void _driveToReady(NewOwnerResetJournal journal) {
  journal.beginReset(retained: _retained);
  journal.completeStage(NewOwnerResetStage.deletion);
  journal.completeStage(NewOwnerResetStage.restoration);
  journal.completeStage(NewOwnerResetStage.verification);
  expect(journal.record!.state, NewOwnerResetState.ready);
}

Map<String, Object?> _validResettingMap() => {
  'schemaVersion': 1,
  'state': 'resetting',
  'stage': 'deletion',
  'armedBySessionId': null,
  'retained': {
    'preferredMachineId': 'synthetic-machine-a',
    'preferredScaleId': 'usb-hds:any',
    'skin': null,
  },
};

bool _mayRestrictPermissions() {
  if (Platform.isWindows) return false;
  final result = Process.runSync('id', ['-u']);
  return result.exitCode == 0 && result.stdout.toString().trim() != '0';
}

class _FaultyStore implements NewOwnerResetJournalStore {
  _FaultyStore(this.inner);

  final NewOwnerResetJournalStore inner;
  bool failWrites = false;
  bool failDeletes = false;

  @override
  NewOwnerResetJournalReadResult read() => inner.read();

  @override
  void write(NewOwnerResetJournalRecord record) {
    if (failWrites) {
      throw const NewOwnerResetJournalWriteException('injected write failure');
    }
    inner.write(record);
  }

  @override
  void delete() {
    if (failDeletes) {
      throw const NewOwnerResetJournalWriteException('injected delete failure');
    }
    inner.delete();
  }
}
