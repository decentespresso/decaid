import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/storage/new_owner_recovery_admission.dart';
import 'package:reaprime/src/services/storage/new_owner_recovery_owner.dart';
import 'package:reaprime/src/services/storage/new_owner_reset_journal.dart';
import 'package:reaprime/src/services/storage/process_session_identity.dart';

const _retained = NewOwnerResetRetainedConfiguration(
  preferredMachineId: 'synthetic-machine-a',
  preferredScaleId: 'usb-hds:any',
  skin: RetainedSkinReference(skinId: 'default', packageId: 'bundled:default'),
);

const _sensitiveInitialisations = <String>[
  'firebase',
  'telemetry',
  'multicast-lock',
  'hive',
  'database',
  'plugins',
  'web-server',
  'account',
  'log-upload',
  'skin-serving',
];

void main() {
  late Directory temp;
  late Directory recoveryDirectory;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('new-owner-recovery-');
    recoveryDirectory = Directory('${temp.path}/recovery');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File journalFile() =>
      File('${recoveryDirectory.path}/$newOwnerResetJournalFileName');

  String claimPath(String session) =>
      '${recoveryDirectory.path}/'
      '${newOwnerRecoveryClaimFileName(session)}';

  NewOwnerResetJournal journal({String session = 'process-1'}) =>
      NewOwnerResetJournal(
        NewOwnerResetJournalFileStore(journalFile()),
        processSessionId: session,
        authority: NewOwnerResetJournalLease(),
      );

  Future<NewOwnerRecoveryStartup> openAdmission({
    String session = 'process-1',
    bool identityUnavailable = false,
  }) async {
    final startup = await NewOwnerRecoveryStartup.open(
      recoveryDirectory: recoveryDirectory.path,
      processSessionId: identityUnavailable ? null : session,
      identity: identityUnavailable
          ? ProcessSessionIdentityResolver(
              probe: _NoProcessFacts(),
              channel: _NoNativeIdentity(),
            )
          : null,
    );
    addTearDown(startup.release);
    return startup;
  }

  /// The production startup boundary: exactly one branch runs, chosen by the
  /// admission, and no test-side decision can run the other one.
  Future<_Boot> boot(NewOwnerRecoveryStartup startup) async {
    final initialised = <String>[];
    var normalStarts = 0;
    await runNewOwnerRecoveryStartup(
      startup: startup,
      startNormalServices: () async {
        normalStarts++;
        initialised.addAll(_sensitiveInitialisations);
      },
      presentBlocked: (admission) {
        initialised.add('recovery-view:${admission.kind.name}');
      },
    );
    return _Boot(initialised: initialised, normalStarts: normalStarts);
  }

  void driveToReady(NewOwnerResetJournal owner) {
    owner.beginReset(retained: _retained);
    owner.completeStage(NewOwnerResetStage.deletion);
    owner.completeStage(NewOwnerResetStage.restoration);
    owner.completeStage(NewOwnerResetStage.verification);
  }

  group('admission states', () {
    test('a missing journal admits the existing normal startup', () async {
      final startup = await openAdmission();

      expect(startup.admission.kind, NewOwnerRecoveryAdmission.normalStartup);
      expect(startup.blocksNormalStartup, isFalse);
      expect(startup.journal, isNull);
      final result = await boot(startup);
      expect(result.initialised, _sensitiveInitialisations);
      expect(result.normalStarts, 1);
    });

    test('a missing journal creates nothing on disk', () async {
      await openAdmission();

      expect(recoveryDirectory.existsSync(), isFalse);
      expect(journalFile().existsSync(), isFalse);
    });

    test('an incomplete reset blocks normal startup', () async {
      recoveryDirectory.createSync(recursive: true);
      final owner = journal()..load();
      owner.beginReset(retained: _retained);
      owner.completeStage(NewOwnerResetStage.deletion);

      final startup = await openAdmission();

      expect(startup.admission.kind, NewOwnerRecoveryAdmission.resetInProgress);
      expect(startup.blocksNormalStartup, isTrue);
      final result = await boot(startup);
      expect(result.initialised, ['recovery-view:resetInProgress']);
      expect(result.normalStarts, 0);
      expect(journalFile().existsSync(), isTrue);
    });

    test('a ready journal is terminal and blocks normal startup', () async {
      recoveryDirectory.createSync(recursive: true);
      final owner = journal()..load();
      driveToReady(owner);

      final startup = await openAdmission();

      expect(
        startup.admission.kind,
        NewOwnerRecoveryAdmission.readyForNewOwner,
      );
      final result = await boot(startup);
      expect(result.initialised, ['recovery-view:readyForNewOwner']);
      expect(result.normalStarts, 0);
    });

    test('a handoff armed by this process stays terminal', () async {
      recoveryDirectory.createSync(recursive: true);
      final owner = journal()..load();
      driveToReady(owner);
      owner.acknowledgeHandoff();

      final startup = await openAdmission();

      expect(
        startup.admission.kind,
        NewOwnerRecoveryAdmission.handoffArmedThisProcess,
      );
      final result = await boot(startup);
      expect(result.initialised, ['recovery-view:handoffArmedThisProcess']);
      expect(result.normalStarts, 0);
    });

    test(
      'a handoff armed by a later process is eligible, not admitted',
      () async {
        recoveryDirectory.createSync(recursive: true);
        final arming = journal();
        arming.load();
        driveToReady(arming);
        arming.acknowledgeHandoff();

        final startup = await openAdmission(session: 'process-2');

        expect(
          startup.admission.kind,
          NewOwnerRecoveryAdmission.handoffEligible,
        );
        final result = await boot(startup);
        expect(result.initialised, ['recovery-view:handoffEligible']);
        expect(result.normalStarts, 0);
        expect(journalFile().existsSync(), isTrue);
        expect(startup.journal!.record!.state, NewOwnerResetState.handoffArmed);
      },
    );

    test('an unreadable journal fails closed with visible detail', () async {
      recoveryDirectory.createSync(recursive: true);
      journalFile().writeAsBytesSync(const <int>[0xff, 0xfe, 0x00]);

      final startup = await openAdmission();

      expect(startup.admission.kind, NewOwnerRecoveryAdmission.uncertain);
      expect(startup.blocksNormalStartup, isTrue);
      expect(startup.admission.detail, isNotNull);
      expect(startup.admission.detail, isNotEmpty);
      final result = await boot(startup);
      expect(result.initialised, ['recovery-view:uncertain']);
      expect(result.normalStarts, 0);
      expect(journalFile().readAsBytesSync(), const <int>[0xff, 0xfe, 0x00]);
    });

    test(
      'a directory at the journal path is uncertain, never absent',
      () async {
        recoveryDirectory.createSync(recursive: true);
        Directory(journalFile().path).createSync();

        final startup = await openAdmission();

        expect(startup.admission.kind, NewOwnerRecoveryAdmission.uncertain);
        expect(Directory(journalFile().path).existsSync(), isTrue);
      },
    );
  });

  group('process identity requirement', () {
    test('pending recovery without a process identity fails closed', () async {
      recoveryDirectory.createSync(recursive: true);
      final owner = journal()..load();
      driveToReady(owner);

      final startup = await openAdmission(identityUnavailable: true);

      expect(startup.admission.kind, NewOwnerRecoveryAdmission.uncertain);
      expect(startup.admission.detail, contains('no process-level identity'));
      expect(startup.journal, isNull);
      final result = await boot(startup);
      expect(result.initialised, ['recovery-view:uncertain']);
      expect(result.normalStarts, 0);
    });

    test('a missing journal needs no process identity', () async {
      final startup = await openAdmission(identityUnavailable: true);

      expect(startup.admission.kind, NewOwnerRecoveryAdmission.normalStartup);
      expect((await boot(startup)).normalStarts, 1);
      expect(recoveryDirectory.existsSync(), isFalse);
    });
  });

  group('ownership boundary', () {
    test('a lock held by another process blocks admission', () async {
      if (!_hasPython()) {
        markTestSkipped('requires python3 for a real second process');
        return;
      }
      recoveryDirectory.createSync(recursive: true);
      final owner = journal()..load();
      driveToReady(owner);
      final lockPath =
          '${recoveryDirectory.path}/$newOwnerRecoveryLockFileName';
      final holder = await Process.start('python3', <String>[
        '-c',
        'import fcntl,sys,time\n'
            'f=open(sys.argv[1],"a")\n'
            'fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n'
            'print("locked",flush=True)\n'
            'time.sleep(30)\n',
        lockPath,
      ]);
      addTearDown(() {
        holder.kill();
        return holder.exitCode;
      });
      final firstLine = await holder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      expect(firstLine, 'locked');

      final startup = await openAdmission();

      expect(startup.admission.kind, NewOwnerRecoveryAdmission.uncertain);
      expect(startup.admission.detail, contains('another Decaid process'));
      final result = await boot(startup);
      expect(result.initialised, ['recovery-view:uncertain']);
      expect(result.normalStarts, 0);
      expect(startup.journal, isNull);
    });

    test('a second engine in this process is refused', () async {
      recoveryDirectory.createSync(recursive: true);
      final owner = journal()..load();
      driveToReady(owner);

      final first = await openAdmission();
      expect(first.admission.kind, NewOwnerRecoveryAdmission.readyForNewOwner);

      final second = await openAdmission();

      expect(second.admission.kind, NewOwnerRecoveryAdmission.uncertain);
      expect(second.admission.detail, contains('another engine'));
      expect(second.journal, isNull);
      expect((await boot(second)).normalStarts, 0);
      expect(first.admission.kind, NewOwnerRecoveryAdmission.readyForNewOwner);
    });

    test(
      'a rejected same-process contender leaves the process lock held',
      () async {
        if (!_hasPython()) {
          markTestSkipped('requires python3 for a real second process');
          return;
        }
        recoveryDirectory.createSync(recursive: true);
        final owner = journal()..load();
        driveToReady(owner);

        final first = await openAdmission();
        expect(
          first.admission.kind,
          NewOwnerRecoveryAdmission.readyForNewOwner,
        );

        final second = await openAdmission();
        expect(second.admission.kind, NewOwnerRecoveryAdmission.uncertain);
        expect(second.admission.detail, contains('another engine'));

        expect(
          await _anotherProcessCanLock(
            '${recoveryDirectory.path}/$newOwnerRecoveryLockFileName',
          ),
          isFalse,
          reason:
              'a rejected engine must not unlock or close the owner\'s '
              'process lock',
        );
        expect(
          first.admission.kind,
          NewOwnerRecoveryAdmission.readyForNewOwner,
        );
      },
    );

    test('release is idempotent and never deletes a successor claim', () async {
      recoveryDirectory.createSync(recursive: true);
      final owner = journal()..load();
      driveToReady(owner);

      final first = await openAdmission();
      expect(first.admission.kind, NewOwnerRecoveryAdmission.readyForNewOwner);
      first.release();

      final successor = await openAdmission();
      expect(
        successor.admission.kind,
        NewOwnerRecoveryAdmission.readyForNewOwner,
      );
      expect(File(claimPath('process-1')).existsSync(), isTrue);

      first.release();

      expect(
        File(claimPath('process-1')).existsSync(),
        isTrue,
        reason: 'a released owner must not delete the successor claim',
      );
      final third = await openAdmission();
      expect(third.admission.kind, NewOwnerRecoveryAdmission.uncertain);
      expect(third.admission.detail, contains('another engine'));
      expect(
        successor.admission.kind,
        NewOwnerRecoveryAdmission.readyForNewOwner,
      );
    });

    test(
      'a successor cannot take ownership while the owner is releasing',
      () async {
        if (!_hasPython()) {
          markTestSkipped('requires python3 for a real competing process');
          return;
        }
        recoveryDirectory.createSync(recursive: true);
        final owner = journal()..load();
        driveToReady(owner);
        final lockPath =
            '${recoveryDirectory.path}/$newOwnerRecoveryLockFileName';

        final first = await openAdmission();
        expect(
          first.admission.kind,
          NewOwnerRecoveryAdmission.readyForNewOwner,
        );

        final facts = <String>[];
        var seamRan = false;
        var successorClaimed = false;
        var successorLocked = false;
        first.releaseInterleaving = () {
          seamRan = true;
          final claim = NewOwnerRecoveryClaim.tryClaim(
            recoveryDirectory,
            'process-1',
          );
          successorClaimed = claim != null;
          facts.add('claim available during release: $successorClaimed');
          if (claim != null) {
            addTearDown(claim.release);
            final lock = NewOwnerRecoveryLock.tryAcquire(File(lockPath));
            successorLocked = lock != null;
            if (lock != null) addTearDown(lock.release);
          }
          facts.add(
            'a competing process could lock during release: '
            '${_anotherProcessCanLockSync(lockPath)}',
          );
        };

        first.release();

        final externalAfterRelease = _anotherProcessCanLockSync(lockPath);
        facts.add(
          'a competing process could lock after release: '
          '$externalAfterRelease',
        );
        facts.add('successor took the process lock: $successorLocked');

        final violations = <String>[
          if (!seamRan) 'the release interleaving seam did not run',
          if (successorClaimed)
            'the claim was removed before the previous lock was released',
          if (successorLocked && externalAfterRelease)
            'the previous release dropped the successor process lock, so a '
                'competing process owns it as well',
        ];

        expect(violations, isEmpty, reason: facts.join('; '));
        expect(File(claimPath('process-1')).existsSync(), isFalse);
        expect(
          externalAfterRelease,
          isTrue,
          reason: 'a completed release must leave no process lock behind',
        );
      },
    );

    test('an earlier process claim blocks only its own identity', () async {
      recoveryDirectory.createSync(recursive: true);
      final arming = journal();
      arming.load();
      driveToReady(arming);
      arming.acknowledgeHandoff();
      File(claimPath('process-1')).createSync(exclusive: true);

      final startup = await openAdmission(session: 'process-2');

      expect(startup.admission.kind, NewOwnerRecoveryAdmission.handoffEligible);
      expect(File(claimPath('process-1')).existsSync(), isTrue);
      expect(File(claimPath('process-2')).existsSync(), isTrue);
    });

    test('releasing the owner lets a later owner admit startup', () async {
      recoveryDirectory.createSync(recursive: true);
      final owner = journal()..load();
      driveToReady(owner);

      final first = await openAdmission();
      expect(first.admission.kind, NewOwnerRecoveryAdmission.readyForNewOwner);
      expect(File(claimPath('process-1')).existsSync(), isTrue);
      first.release();
      first.release();

      expect(File(claimPath('process-1')).existsSync(), isFalse);

      final second = await openAdmission();

      expect(second.admission.kind, NewOwnerRecoveryAdmission.readyForNewOwner);
      expect(File(claimPath('process-1')).existsSync(), isTrue);
    });

    test('ownership files stay inside the recovery directory', () async {
      recoveryDirectory.createSync(recursive: true);
      final owner = journal()..load();
      owner.beginReset(retained: _retained);

      final startup = await openAdmission();

      expect(
        startup.journalPath,
        '${recoveryDirectory.path}/$newOwnerResetJournalFileName',
      );
      expect(
        File('${recoveryDirectory.path}/$newOwnerRecoveryLockFileName')
            .existsSync(),
        isTrue,
      );
      expect(File(claimPath('process-1')).existsSync(), isTrue);
      expect(File(claimPath('process-1')).parent.path, recoveryDirectory.path);
      expect(temp.listSync().length, 1);
    });

    test('claim names are derived from the full identity', () {
      final first = newOwnerRecoveryClaimFileName('proc:boot-a:42:1234');
      final second = newOwnerRecoveryClaimFileName('proc:boot-a:42:12345');

      expect(first, isNot(second));
      expect(first, endsWith(newOwnerRecoveryClaimSuffix));
      expect(first, startsWith(newOwnerRecoveryClaimPrefix));
      expect(first, matches(RegExp(r'^[A-Za-z0-9_.-]+$')));
      expect(newOwnerRecoveryClaimFileName('proc:boot-a:42:1234'), first);
    });
  });

  group('revocable owner lease', () {
    test(
      'a released owner cannot mutate a marker its successor owns',
      () async {
        recoveryDirectory.createSync(recursive: true);
        final preparer = journal()..load();
        driveToReady(preparer);

        final first = await openAdmission();
        expect(
          first.admission.kind,
          NewOwnerRecoveryAdmission.readyForNewOwner,
        );
        final stale = first.journal!;
        final marker = journalFile().readAsBytesSync();

        first.release();

        final successor = await openAdmission();
        expect(
          successor.admission.kind,
          NewOwnerRecoveryAdmission.readyForNewOwner,
        );
        expect(journalFile().readAsBytesSync(), marker);
        expect(successor.journal!.record!.state, NewOwnerResetState.ready);

        expect(
          stale.acknowledgeHandoff,
          throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
        );
        expect(journalFile().readAsBytesSync(), marker);
        expect(successor.journal!.record!.state, NewOwnerResetState.ready);

        successor.journal!.acknowledgeHandoff();

        expect(
          successor.journal!.record!.state,
          NewOwnerResetState.handoffArmed,
        );
      },
    );

    test(
      'a released owner can neither reload nor delete its successor handoff',
      () async {
        recoveryDirectory.createSync(recursive: true);
        final armingProcess = journal(session: 'process-0')..load();
        driveToReady(armingProcess);
        armingProcess.acknowledgeHandoff();

        final first = await openAdmission();
        expect(first.admission.kind, NewOwnerRecoveryAdmission.handoffEligible);
        final stale = first.journal!;
        final armed = journalFile().readAsBytesSync();

        first.release();
        final successor = await openAdmission();
        expect(
          successor.admission.kind,
          NewOwnerRecoveryAdmission.handoffEligible,
        );

        expect(stale.load(), isA<NewOwnerResetJournalPresent>());
        expect(stale.record!.state, NewOwnerResetState.handoffArmed);
        expect(
          stale.consumeHandoff,
          throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
        );

        expect(journalFile().readAsBytesSync(), armed);
        expect(
          successor.journal!.record!.state,
          NewOwnerResetState.handoffArmed,
        );
        successor.journal!.consumeHandoff();
        expect(journalFile().existsSync(), isFalse);
      },
    );

    test('a no-op duplicate stage still requires the lease', () async {
      recoveryDirectory.createSync(recursive: true);
      final preparer = journal()..load();
      preparer.beginReset(retained: _retained);
      preparer.completeStage(NewOwnerResetStage.deletion);
      final marker = journalFile().readAsBytesSync();

      final first = await openAdmission();
      expect(first.admission.kind, NewOwnerRecoveryAdmission.resetInProgress);
      final stale = first.journal!;

      first.release();
      final successor = await openAdmission();
      expect(
        successor.admission.kind,
        NewOwnerRecoveryAdmission.resetInProgress,
      );

      expect(
        () => stale.completeStage(NewOwnerResetStage.deletion),
        throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
      );
      expect(
        () => stale.beginReset(retained: _retained),
        throwsA(isA<NewOwnerResetJournalLeaseRevokedException>()),
      );

      expect(journalFile().readAsBytesSync(), marker);
      successor.journal!.completeStage(NewOwnerResetStage.deletion);
      expect(
        successor.journal!.record!.stage,
        NewOwnerResetStage.restoration,
        reason: 'a repeated stage stays a no-op for the current owner',
      );
      successor.journal!.completeStage(NewOwnerResetStage.restoration);
      expect(successor.journal!.record!.stage, NewOwnerResetStage.verification);
    });

    test(
      'release revokes mutation authority before ownership is dropped',
      () async {
        recoveryDirectory.createSync(recursive: true);
        final preparer = journal()..load();
        driveToReady(preparer);

        final first = await openAdmission();
        final stale = first.journal!;
        final marker = journalFile().readAsBytesSync();
        final facts = <String>[];
        var revokedInWindow = false;
        first.releaseInterleaving = () {
          try {
            stale.acknowledgeHandoff();
          } on NewOwnerResetJournalLeaseRevokedException {
            revokedInWindow = true;
          }
          facts.add(
            'authority revoked inside the release window: $revokedInWindow; '
            'claim still present: '
            '${File(claimPath('process-1')).existsSync()}; '
            'marker unchanged: '
            '${_sameBytes(journalFile().readAsBytesSync(), marker)}',
          );
        };

        first.release();

        expect(revokedInWindow, isTrue, reason: facts.join('; '));
        expect(journalFile().readAsBytesSync(), marker);
      },
    );
  });

  group('production wiring', () {
    test('main starts no sensitive service outside the recovery boundary', () {
      final source = File('lib/main.dart').readAsStringSync();
      final boundary = source.indexOf('runNewOwnerRecoveryStartup(');
      final normalStart = source.indexOf(
        'Future<void> startDecaidNormalServices(',
      );

      expect(boundary, greaterThan(0));
      expect(normalStart, greaterThan(boundary));
      for (final marker in const <String>[
        'MulticastLockService().acquire()',
        'Firebase.initializeApp(',
        'telemetryService.initialize()',
        'Hive.init(',
        'AppDatabase.defaults()',
        'PluginLoaderService(',
        'WebUIService(',
      ]) {
        final index = source.indexOf(marker);
        expect(index, greaterThan(normalStart), reason: marker);
        expect(
          source.indexOf(marker, index + 1),
          -1,
          reason: '$marker must appear exactly once',
        );
      }
    });

    test('the Android manifest removes the automatic Firebase initialiser', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();

      expect(
        manifest,
        contains('xmlns:tools="http://schemas.android.com/tools"'),
        reason: 'a removal node needs the tools namespace declared',
      );
      expect(
        RegExp(
          r'<provider\s+android:name="com\.google\.firebase\.provider\.'
          r'FirebaseInitProvider"[^>]*tools:node="remove"',
        ).hasMatch(manifest),
        isTrue,
        reason:
            'FirebaseInitProvider creates the default Firebase app before any '
            'Dart admission decision runs',
      );
    });
  });

  group('decision', () {
    const retained = _retained;

    test('maps every readable state deterministically', () {
      expect(
        decideNewOwnerRecoveryAdmission(
          const NewOwnerResetJournalAbsent(),
          processSessionId: 'process-1',
        ).kind,
        NewOwnerRecoveryAdmission.normalStartup,
      );
      expect(
        decideNewOwnerRecoveryAdmission(
          const NewOwnerResetJournalPresent(
            NewOwnerResetJournalRecord.resetting(
              stage: NewOwnerResetStage.verification,
              retained: retained,
            ),
          ),
          processSessionId: 'process-1',
        ).kind,
        NewOwnerRecoveryAdmission.resetInProgress,
      );
      expect(
        decideNewOwnerRecoveryAdmission(
          const NewOwnerResetJournalPresent(
            NewOwnerResetJournalRecord.ready(retained: retained),
          ),
          processSessionId: 'process-1',
        ).kind,
        NewOwnerRecoveryAdmission.readyForNewOwner,
      );
      expect(
        decideNewOwnerRecoveryAdmission(
          const NewOwnerResetJournalPresent(
            NewOwnerResetJournalRecord.handoffArmed(
              retained: retained,
              armedBySessionId: 'process-1',
            ),
          ),
          processSessionId: 'process-1',
        ).kind,
        NewOwnerRecoveryAdmission.handoffArmedThisProcess,
      );
      expect(
        decideNewOwnerRecoveryAdmission(
          const NewOwnerResetJournalPresent(
            NewOwnerResetJournalRecord.handoffArmed(
              retained: retained,
              armedBySessionId: 'process-1',
            ),
          ),
          processSessionId: 'process-2',
        ).kind,
        NewOwnerRecoveryAdmission.handoffEligible,
      );
      expect(
        decideNewOwnerRecoveryAdmission(
          const NewOwnerResetJournalUnreadable('disk on fire'),
          processSessionId: 'process-1',
        ).kind,
        NewOwnerRecoveryAdmission.uncertain,
      );
    });

    test('only normal startup permits normal services to start', () {
      for (final kind in NewOwnerRecoveryAdmission.values) {
        final decision = NewOwnerRecoveryAdmissionDecision(kind);
        expect(
          decision.permitsNormalStartup,
          kind == NewOwnerRecoveryAdmission.normalStartup,
          reason: kind.name,
        );
      }
    });
  });
}

final class _Boot {
  const _Boot({required this.initialised, required this.normalStarts});

  final List<String> initialised;
  final int normalStarts;
}

class _NoProcessFacts implements ProcessSessionProbe {
  @override
  String? readBootId() => null;

  @override
  String? readProcessStartTicks() => null;

  @override
  int get processId => 0;
}

class _NoNativeIdentity implements ProcessSessionIdentityChannel {
  @override
  Future<String?> resolve() async => null;
}

/// Takes the recovery lock from a genuinely separate process non-blockingly,
/// returning whether that process could acquire it.
Future<bool> _anotherProcessCanLock(String lockPath) async {
  final probe = await Process.start('python3', <String>[
    '-c',
    'import fcntl,sys\n'
        'f=open(sys.argv[1],"a")\n'
        'try:\n'
        '    fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n'
        'except OSError:\n'
        '    print("blocked",flush=True)\n'
        'else:\n'
        '    print("acquired",flush=True)\n',
    lockPath,
  ]);
  final verdict = await probe.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  await probe.exitCode;
  return verdict == 'acquired';
}

/// Synchronous form of [_anotherProcessCanLock], for seams that cannot await.
bool _anotherProcessCanLockSync(String lockPath) {
  final probe = Process.runSync('python3', <String>[
    '-c',
    'import fcntl,sys\n'
        'f=open(sys.argv[1],"a")\n'
        'try:\n'
        '    fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n'
        'except OSError:\n'
        '    print("blocked",flush=True)\n'
        'else:\n'
        '    print("acquired",flush=True)\n',
    lockPath,
  ]);
  final verdict = (probe.stdout as String).trim();
  return verdict == 'acquired';
}

bool _hasPython() {
  final probe = Process.runSync('python3', const <String>['--version']);
  return probe.exitCode == 0;
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
