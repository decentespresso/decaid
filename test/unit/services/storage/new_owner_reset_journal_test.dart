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
    NewOwnerResetJournalLease? lease,
  }) => NewOwnerResetJournal(
    backing ?? store(),
    processSessionId: session,
    authority: lease ?? NewOwnerResetJournalLease(),
  );

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
            authority: NewOwnerResetJournalLease(),
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
          authority: NewOwnerResetJournalLease(),
        )..load();
        _driveToReady(arming);
        arming.acknowledgeHandoff();
        final armedRaw = lockedJournal.readAsStringSync();
        final nextProcess = NewOwnerResetJournal(
          NewOwnerResetJournalFileStore(lockedJournal),
          processSessionId: 'process-2',
          authority: NewOwnerResetJournalLease(),
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

  group('marker encoding', () {
    test('invalid UTF-8 content is unreadable, not absent', () {
      final raw = <int>[0x7b, 0x22, 0xff, 0xfe, 0x22, 0x7d];
      journalFile.writeAsBytesSync(raw);

      final journal = open();
      final result = journal.load();

      expect(result, isA<NewOwnerResetJournalUnreadable>());
      expect(
        (result as NewOwnerResetJournalUnreadable).reason,
        contains('UTF-8'),
      );
      expect(journal.record, isNull);
      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(journalFile.readAsBytesSync(), raw);
    });

    test('a truncated multi-byte sequence is unreadable too', () {
      journalFile.writeAsBytesSync(<int>[
        ...utf8.encode('{"state":"resetting"'),
        0xe2,
        0x82,
      ]);

      final journal = open();

      expect(journal.load(), isA<NewOwnerResetJournalUnreadable>());
      expect(
        () => journal.consumeHandoff(),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
    });
  });

  group('retained skin shape', () {
    final invalidSkins = <String, Object?>{
      'a missing packageId': {'skinId': 'default'},
      'a missing skinId': {'packageId': 'bundled:default'},
      'an unexpected nested field': {
        'skinId': 'default',
        'packageId': 'bundled:default',
        'personalState': 'factory',
      },
      'a blank nested value': {'skinId': '   ', 'packageId': 'bundled:default'},
      'a list': ['default', 'bundled:default'],
      'a bare string': 'default',
    };

    invalidSkins.forEach((label, skin) {
      test('$label is unreadable and never overwritten', () {
        final raw = jsonEncode({
          ..._validResettingMap(),
          'retained': {
            'preferredMachineId': 'synthetic-machine-a',
            'preferredScaleId': 'usb-hds:any',
            'skin': skin,
          },
        });
        journalFile.writeAsStringSync(raw);

        final journal = open();

        expect(journal.load(), isA<NewOwnerResetJournalUnreadable>());
        expect(
          () => journal.completeStage(NewOwnerResetStage.deletion),
          throwsA(isA<NewOwnerResetJournalStateException>()),
        );
        expect(journalFile.readAsStringSync(), raw);
      });
    });

    test('a retained configuration without the skin field is unreadable', () {
      journalFile.writeAsStringSync(
        jsonEncode({
          ..._validResettingMap(),
          'retained': {
            'preferredMachineId': 'synthetic-machine-a',
            'preferredScaleId': 'usb-hds:any',
          },
        }),
      );

      expect(open().load(), isA<NewOwnerResetJournalUnreadable>());
    });
  });

  group('unreadable owner', () {
    test('the instance that loaded unreadable state cannot mutate it', () {
      Directory(journalFile.path).createSync();
      final journal = open();

      expect(journal.load(), isA<NewOwnerResetJournalUnreadable>());
      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(journal.record, isNull);
      expect(Directory(journalFile.path).existsSync(), isTrue);
    });

    test('the same instance cannot acknowledge or consume it', () {
      journalFile.writeAsBytesSync(const <int>[0xff, 0xfe]);
      final journal = open();

      expect(journal.load(), isA<NewOwnerResetJournalUnreadable>());
      expect(
        () => journal.acknowledgeHandoff(),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(
        () => journal.consumeHandoff(),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(journalFile.readAsBytesSync(), const <int>[0xff, 0xfe]);
    });
  });

  group('staged write faults', () {
    late _FaultyFileOperations operations;

    setUp(() {
      operations = _FaultyFileOperations();
    });

    NewOwnerResetJournal faultyJournal() => NewOwnerResetJournal(
      NewOwnerResetJournalFileStore(journalFile, operations: operations),
      processSessionId: 'process-1',
      authority: NewOwnerResetJournalLease(),
    )..load();

    test('a byte-write fault publishes nothing', () {
      final journal = faultyJournal();
      operations.failBytes = true;

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(journal.record, isNull);
      expect(journalFile.existsSync(), isFalse);
      expect(File('${journalFile.path}.tmp').existsSync(), isFalse);
    });

    test('a flush fault publishes nothing and leaves no staging file', () {
      final journal = faultyJournal();
      operations.failFlush = true;

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(journal.record, isNull);
      expect(journalFile.existsSync(), isFalse);
      expect(File('${journalFile.path}.tmp').existsSync(), isFalse);
    });

    test('a close fault publishes nothing and leaves no staging file', () {
      final journal = faultyJournal();
      operations.failClose = true;

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(journal.record, isNull);
      expect(journalFile.existsSync(), isFalse);
      expect(File('${journalFile.path}.tmp').existsSync(), isFalse);
    });

    test('a rename fault keeps the previous record and cleans staging', () {
      final journal = faultyJournal();
      journal.beginReset(retained: _retained);
      final raw = journalFile.readAsStringSync();
      operations.failRename = true;

      expect(
        () => journal.completeStage(NewOwnerResetStage.deletion),
        throwsA(
          allOf(
            isA<NewOwnerResetJournalWriteException>(),
            isNot(isA<NewOwnerResetJournalIndeterminateWriteException>()),
          ),
        ),
      );

      expect(journal.record!.stage, NewOwnerResetStage.deletion);
      expect(journal.durableStateUnknown, isFalse);
      expect(journalFile.readAsStringSync(), raw);
      expect(File('${journalFile.path}.tmp').existsSync(), isFalse);
    });
  });

  group('ambiguous persistence outcomes', () {
    late _FaultyFileOperations operations;

    setUp(() {
      operations = _FaultyFileOperations();
    });

    NewOwnerResetJournal faultyJournal({String session = 'process-1'}) =>
        NewOwnerResetJournal(
          NewOwnerResetJournalFileStore(journalFile, operations: operations),
          processSessionId: session,
          authority: NewOwnerResetJournalLease(),
        )..load();

    test('a replace that committed before failing is a success', () {
      final journal = faultyJournal();
      journal.beginReset(retained: _retained);
      operations.renameCommitsThenFails = true;

      journal.completeStage(NewOwnerResetStage.deletion);

      expect(journal.record!.stage, NewOwnerResetStage.restoration);
      expect(journal.durableStateUnknown, isFalse);
      final reloaded = open()..load();
      expect(reloaded.record!.stage, NewOwnerResetStage.restoration);
    });

    test('a replace that left unreadable state fails closed', () {
      final journal = faultyJournal();
      journal.beginReset(retained: _retained);
      operations.corruptOnRenameFailure = true;

      expect(
        () => journal.completeStage(NewOwnerResetStage.deletion),
        throwsA(isA<NewOwnerResetJournalIndeterminateWriteException>()),
      );

      expect(journal.durableStateUnknown, isTrue);
      expect(
        () => journal.completeStage(NewOwnerResetStage.deletion),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
      expect(open().load(), isA<NewOwnerResetJournalUnreadable>());
    });

    test('a delete that removed the marker before failing consumes', () {
      final arming = open()..load();
      _driveToReady(arming);
      arming.acknowledgeHandoff();
      final nextProcess = faultyJournal(session: 'process-2');
      operations.deleteCommitsThenFails = true;

      nextProcess.consumeHandoff();

      expect(nextProcess.record, isNull);
      expect(nextProcess.durableStateUnknown, isFalse);
      expect(journalFile.existsSync(), isFalse);
    });

    test('a delete that left unreadable state fails closed', () {
      final arming = open()..load();
      _driveToReady(arming);
      arming.acknowledgeHandoff();
      final nextProcess = faultyJournal(session: 'process-2');
      operations.deleteCorruptsThenFails = true;

      expect(
        () => nextProcess.consumeHandoff(),
        throwsA(isA<NewOwnerResetJournalIndeterminateWriteException>()),
      );

      expect(nextProcess.record!.state, NewOwnerResetState.handoffArmed);
      expect(nextProcess.durableStateUnknown, isTrue);
      expect(open().load(), isA<NewOwnerResetJournalUnreadable>());
    });
  });

  group('replacement outcome classification', () {
    late _FaultyFileOperations operations;

    setUp(() {
      operations = _FaultyFileOperations();
    });

    NewOwnerResetJournal faultyJournal({String session = 'process-1'}) =>
        NewOwnerResetJournal(
          NewOwnerResetJournalFileStore(journalFile, operations: operations),
          processSessionId: session,
          authority: NewOwnerResetJournalLease(),
        )..load();

    test(
      'an unrelated third record after a failed replace is indeterminate',
      () {
        final journal = faultyJournal();
        journal.beginReset(retained: _retained);
        operations
          ..thirdRecord = const NewOwnerResetJournalRecord.resetting(
            stage: NewOwnerResetStage.verification,
            retained: _retained,
          )
          ..writeThirdRecordOnRenameFailure = true;

        expect(
          () => journal.completeStage(NewOwnerResetStage.deletion),
          throwsA(isA<NewOwnerResetJournalIndeterminateWriteException>()),
        );

        expect(journal.record!.stage, NewOwnerResetStage.deletion);
        expect(journal.durableStateUnknown, isTrue);
        expect(
          () => journal.completeStage(NewOwnerResetStage.deletion),
          throwsA(isA<NewOwnerResetJournalStateException>()),
        );
        final observed = store().read();
        expect(
          (observed as NewOwnerResetJournalPresent).record.stage,
          NewOwnerResetStage.verification,
        );
        final reloaded = open(session: 'process-2')..load();
        expect(reloaded.record!.stage, NewOwnerResetStage.verification);
      },
    );

    test('a lost marker after a failed replace is indeterminate', () {
      final journal = faultyJournal();
      journal.beginReset(retained: _retained);
      operations.loseMarkerOnRenameFailure = true;

      expect(
        () => journal.completeStage(NewOwnerResetStage.deletion),
        throwsA(isA<NewOwnerResetJournalIndeterminateWriteException>()),
      );

      expect(journal.record!.stage, NewOwnerResetStage.deletion);
      expect(journal.durableStateUnknown, isTrue);
      expect(journalFile.existsSync(), isFalse);
      expect(File('${journalFile.path}.tmp').existsSync(), isFalse);
      expect(
        () => journal.completeStage(NewOwnerResetStage.deletion),
        throwsA(isA<NewOwnerResetJournalStateException>()),
      );
    });

    test(
      'the lost-marker latch is in-memory and a reload re-reads durably',
      () {
        final journal = faultyJournal();
        journal.beginReset(retained: _retained);
        operations.loseMarkerOnRenameFailure = true;
        expect(
          () => journal.completeStage(NewOwnerResetStage.deletion),
          throwsA(isA<NewOwnerResetJournalIndeterminateWriteException>()),
        );

        final rebuilt = open(session: 'process-2');

        expect(rebuilt.load(), isA<NewOwnerResetJournalAbsent>());
        expect(rebuilt.record, isNull);
        expect(rebuilt.durableStateUnknown, isFalse);
        expect(journal.durableStateUnknown, isTrue);

        expect(journal.load(), isA<NewOwnerResetJournalAbsent>());
        expect(journal.record, isNull);
        expect(journal.durableStateUnknown, isFalse);
      },
    );

    test('a replace that never staged stays a definite rejection', () {
      final journal = faultyJournal();
      operations.failRename = true;

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(
          allOf(
            isA<NewOwnerResetJournalWriteException>(),
            isNot(isA<NewOwnerResetJournalIndeterminateWriteException>()),
          ),
        ),
      );

      expect(journal.record, isNull);
      expect(journal.durableStateUnknown, isFalse);
      expect(journalFile.existsSync(), isFalse);
    });

    test('an unreadable marker is never overwritten by a store write', () {
      const corrupt = '{not json';
      journalFile.writeAsStringSync(corrupt);

      expect(
        () => store().write(
          const NewOwnerResetJournalRecord.resetting(
            stage: NewOwnerResetStage.deletion,
            retained: _retained,
          ),
        ),
        throwsA(
          allOf(
            isA<NewOwnerResetJournalWriteException>(),
            isNot(isA<NewOwnerResetJournalIndeterminateWriteException>()),
          ),
        ),
      );

      expect(journalFile.readAsStringSync(), corrupt);
      expect(File('${journalFile.path}.tmp').existsSync(), isFalse);
    });
  });

  group('competing journal owners', () {
    test('a stale instance cannot overwrite a created journal', () {
      final first = open(session: 'process-1')..load();
      final stale = open(session: 'process-2')..load();
      first.beginReset(retained: _retained);

      expect(
        () => stale.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(stale.record, isNull);
      final reloaded = open()..load();
      expect(reloaded.record!.stage, NewOwnerResetStage.deletion);
    });

    test('a stale instance cannot rewind an advanced stage', () {
      final first = open()..load();
      first.beginReset(retained: _retained);
      final stale = open()..load();
      first.completeStage(NewOwnerResetStage.deletion);

      expect(
        () => stale.completeStage(NewOwnerResetStage.deletion),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      expect(stale.record!.stage, NewOwnerResetStage.deletion);
      final reloaded = open()..load();
      expect(reloaded.record!.stage, NewOwnerResetStage.restoration);
    });

    test('only one of two later processes consumes the handoff', () {
      final arming = open()..load();
      _driveToReady(arming);
      arming.acknowledgeHandoff();
      final firstLater = open(session: 'process-2')..load();
      final secondLater = open(session: 'process-3')..load();

      firstLater.consumeHandoff();

      expect(
        () => secondLater.consumeHandoff(),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );
      expect(journalFile.existsSync(), isFalse);
    });

    test('a stale instance stays refused until it reloads', () {
      final first = open()..load();
      final stale = open()..load();
      first.beginReset(retained: _retained);

      expect(
        () => stale.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );
      expect(
        () => stale.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalWriteException>()),
      );

      stale.load();
      expect(stale.record!.stage, NewOwnerResetStage.deletion);
      stale.completeStage(NewOwnerResetStage.deletion);
      final reloaded = open()..load();
      expect(reloaded.record!.stage, NewOwnerResetStage.restoration);
    });
  });

  group('revoked authority', () {
    test('every mutator refuses a revoked handle and writes nothing', () {
      final lease = NewOwnerResetJournalLease();
      final journal = open(lease: lease)..load();
      journal.beginReset(retained: _retained);
      final marker = journalFile.readAsStringSync();

      lease.revoke();

      expect(
        () => journal.completeStage(NewOwnerResetStage.deletion),
        throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
      );
      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
      );
      expect(
        journal.acknowledgeHandoff,
        throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
      );
      expect(
        journal.consumeHandoff,
        throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
      );
      expect(journalFile.readAsStringSync(), marker);
    });

    test('a reload never reissues authority', () {
      final lease = NewOwnerResetJournalLease();
      final journal = open(lease: lease)..load();
      _driveToReady(journal);
      journal.acknowledgeHandoff();
      final marker = journalFile.readAsStringSync();

      lease.revoke();
      journal.load();

      expect(
        () => journal.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
      );
      expect(
        journal.consumeHandoff,
        throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
      );
      expect(journalFile.readAsStringSync(), marker);
      expect(lease.isRevoked, isTrue);
    });

    test('a no-op duplicate stage cannot pass a revoked lease', () {
      final lease = NewOwnerResetJournalLease();
      final journal = open(lease: lease)..load();
      journal.beginReset(retained: _retained);
      journal.completeStage(NewOwnerResetStage.deletion);
      final marker = journalFile.readAsStringSync();

      lease.revoke();

      expect(
        () => journal.completeStage(NewOwnerResetStage.deletion),
        throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
      );
      expect(journalFile.readAsStringSync(), marker);
    });

    test('an unrevoked lease keeps the standalone handle usable', () {
      final lease = NewOwnerResetJournalLease();
      final journal = open(lease: lease)..load();

      _driveToReady(journal);

      expect(lease.isRevoked, isFalse);
      expect(journal.record!.state, NewOwnerResetState.ready);
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

class _FaultyFileOperations implements NewOwnerResetJournalFileOperations {
  final NewOwnerResetJournalFileOperations _inner =
      const IoNewOwnerResetJournalFileOperations();

  bool failBytes = false;
  bool failFlush = false;
  bool failClose = false;
  bool failRename = false;
  bool renameCommitsThenFails = false;
  bool corruptOnRenameFailure = false;
  bool loseMarkerOnRenameFailure = false;
  bool writeThirdRecordOnRenameFailure = false;
  bool deleteCommitsThenFails = false;
  bool deleteCorruptsThenFails = false;
  NewOwnerResetJournalRecord? thirdRecord;

  @override
  FileSystemEntityType typeSync(String path) => _inner.typeSync(path);

  @override
  List<int> readBytesSync(String path) => _inner.readBytesSync(path);

  @override
  int lengthSync(String path) => _inner.lengthSync(path);

  @override
  NewOwnerResetJournalStagedWrite openStaged(String path) =>
      _FaultyStagedWrite(this, _inner.openStaged(path));

  @override
  void renameSync(String from, String to) {
    if (renameCommitsThenFails) {
      _inner.renameSync(from, to);
      throw const FileSystemException('injected rename failure after commit');
    }
    if (corruptOnRenameFailure) {
      File(to).writeAsBytesSync(const <int>[0xff, 0xfe, 0x00]);
      throw const FileSystemException('injected rename failure, state unknown');
    }
    if (loseMarkerOnRenameFailure) {
      if (FileSystemEntity.typeSync(to) == FileSystemEntityType.file) {
        _inner.deleteSync(to);
      }
      throw const FileSystemException('injected rename failure, marker lost');
    }
    if (writeThirdRecordOnRenameFailure) {
      File(to).writeAsStringSync(jsonEncode(thirdRecord!.toJson()));
      throw const FileSystemException(
        'injected rename failure, unrelated record observed',
      );
    }
    if (failRename) {
      throw const FileSystemException('injected rename failure');
    }
    _inner.renameSync(from, to);
  }

  @override
  void deleteSync(String path) {
    if (deleteCommitsThenFails) {
      _inner.deleteSync(path);
      throw const FileSystemException('injected delete failure after commit');
    }
    if (deleteCorruptsThenFails) {
      File(path).writeAsBytesSync(const <int>[0xff]);
      throw const FileSystemException('injected delete failure, state unknown');
    }
    _inner.deleteSync(path);
  }
}

class _FaultyStagedWrite implements NewOwnerResetJournalStagedWrite {
  _FaultyStagedWrite(this._owner, this._inner);

  final _FaultyFileOperations _owner;
  final NewOwnerResetJournalStagedWrite _inner;

  @override
  void writeBytes(List<int> bytes) {
    if (_owner.failBytes) {
      throw const FileSystemException('injected byte-write failure');
    }
    _inner.writeBytes(bytes);
  }

  @override
  void flush() {
    if (_owner.failFlush) {
      throw const FileSystemException('injected flush failure');
    }
    _inner.flush();
  }

  @override
  void close() {
    if (_owner.failClose) {
      _inner.close();
      throw const FileSystemException('injected close failure');
    }
    _inner.close();
  }
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
