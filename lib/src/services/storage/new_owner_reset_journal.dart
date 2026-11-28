import 'dart:convert';
import 'dart:io';

const int newOwnerResetJournalSchemaVersion = 1;

const String newOwnerResetJournalFileName = 'new-owner-reset-journal.json';

enum NewOwnerResetState { resetting, ready, handoffArmed }

enum NewOwnerResetStage { deletion, restoration, verification }

final class RetainedSkinReference {
  const RetainedSkinReference({required this.skinId, required this.packageId});

  static const Set<String> _keys = {'skinId', 'packageId'};

  final String skinId;
  final String packageId;

  Map<String, Object?> toJson() => {'skinId': skinId, 'packageId': packageId};

  static RetainedSkinReference fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException(
        'journal retained skin must be a JSON object',
      );
    }
    _rejectUnknownKeys(json, _keys, 'journal retained skin');
    _requireKeys(json, _keys, 'journal retained skin');
    return RetainedSkinReference(
      skinId: _requireNonEmptyString(json['skinId'], 'skinId'),
      packageId: _requireNonEmptyString(json['packageId'], 'packageId'),
    );
  }
}

final class NewOwnerResetRetainedConfiguration {
  const NewOwnerResetRetainedConfiguration({
    this.preferredMachineId,
    this.preferredScaleId,
    this.skin,
  });

  static const Set<String> _keys = {
    'preferredMachineId',
    'preferredScaleId',
    'skin',
  };

  final String? preferredMachineId;
  final String? preferredScaleId;
  final RetainedSkinReference? skin;

  Map<String, Object?> toJson() => {
    'preferredMachineId': preferredMachineId,
    'preferredScaleId': preferredScaleId,
    'skin': skin?.toJson(),
  };

  static NewOwnerResetRetainedConfiguration fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException(
        'journal retained configuration must be a JSON object',
      );
    }
    _rejectUnknownKeys(json, _keys, 'journal retained configuration');
    _requireKeys(json, _keys, 'journal retained configuration');
    final skin = json['skin'];
    return NewOwnerResetRetainedConfiguration(
      preferredMachineId: _optionalNonEmptyString(
        json['preferredMachineId'],
        'preferredMachineId',
      ),
      preferredScaleId: _optionalNonEmptyString(
        json['preferredScaleId'],
        'preferredScaleId',
      ),
      skin: skin == null ? null : RetainedSkinReference.fromJson(skin),
    );
  }
}

final class NewOwnerResetJournalRecord {
  const NewOwnerResetJournalRecord._({
    required this.state,
    required this.retained,
    this.stage,
    this.armedBySessionId,
  });

  const NewOwnerResetJournalRecord.resetting({
    required NewOwnerResetStage stage,
    required NewOwnerResetRetainedConfiguration retained,
  }) : this._(
         state: NewOwnerResetState.resetting,
         stage: stage,
         retained: retained,
       );

  const NewOwnerResetJournalRecord.ready({
    required NewOwnerResetRetainedConfiguration retained,
  }) : this._(state: NewOwnerResetState.ready, retained: retained);

  const NewOwnerResetJournalRecord.handoffArmed({
    required NewOwnerResetRetainedConfiguration retained,
    required String armedBySessionId,
  }) : this._(
         state: NewOwnerResetState.handoffArmed,
         retained: retained,
         armedBySessionId: armedBySessionId,
       );

  static const Set<String> _keys = {
    'schemaVersion',
    'state',
    'stage',
    'retained',
    'armedBySessionId',
  };

  final NewOwnerResetState state;
  final NewOwnerResetStage? stage;
  final NewOwnerResetRetainedConfiguration retained;
  final String? armedBySessionId;

  Map<String, Object?> toJson() => {
    'schemaVersion': newOwnerResetJournalSchemaVersion,
    'state': state.name,
    'stage': stage?.name,
    'retained': retained.toJson(),
    'armedBySessionId': armedBySessionId,
  };

  static NewOwnerResetJournalRecord fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('journal record must be a JSON object');
    }
    _rejectUnknownKeys(json, _keys, 'journal record');
    _requireKeys(json, _keys, 'journal record');

    final version = json['schemaVersion'];
    if (version is! int || version != newOwnerResetJournalSchemaVersion) {
      throw FormatException('unsupported journal schema version "$version"');
    }

    final state = _enumByName(
      NewOwnerResetState.values,
      json['state'],
      'state',
    );
    final stageName = json['stage'];
    final stage = stageName == null
        ? null
        : _enumByName(NewOwnerResetStage.values, stageName, 'stage');
    final armedBySessionId = _optionalNonEmptyString(
      json['armedBySessionId'],
      'armedBySessionId',
    );

    if (state == NewOwnerResetState.resetting && stage == null) {
      throw const FormatException('resetting journal requires a stage');
    }
    if (state != NewOwnerResetState.resetting && stage != null) {
      throw FormatException(
        'journal state ${state.name} must not carry a stage',
      );
    }
    if (state == NewOwnerResetState.handoffArmed && armedBySessionId == null) {
      throw const FormatException(
        'handoff-armed journal requires armedBySessionId',
      );
    }
    if (state != NewOwnerResetState.handoffArmed && armedBySessionId != null) {
      throw FormatException(
        'journal state ${state.name} must not carry armedBySessionId',
      );
    }

    return NewOwnerResetJournalRecord._(
      state: state,
      stage: stage,
      retained: NewOwnerResetRetainedConfiguration.fromJson(json['retained']),
      armedBySessionId: armedBySessionId,
    );
  }
}

sealed class NewOwnerResetJournalReadResult {
  const NewOwnerResetJournalReadResult();
}

final class NewOwnerResetJournalAbsent extends NewOwnerResetJournalReadResult {
  const NewOwnerResetJournalAbsent();
}

final class NewOwnerResetJournalPresent extends NewOwnerResetJournalReadResult {
  const NewOwnerResetJournalPresent(this.record);

  final NewOwnerResetJournalRecord record;
}

final class NewOwnerResetJournalUnreadable
    extends NewOwnerResetJournalReadResult {
  const NewOwnerResetJournalUnreadable(this.reason);

  final String reason;
}

final class NewOwnerResetJournalStateException implements Exception {
  const NewOwnerResetJournalStateException(this.message);

  final String message;

  @override
  String toString() => 'NewOwnerResetJournalStateException: $message';
}

/// Revocable authority to mutate one journal handle.
///
/// The owning composition creates exactly one lease, attaches it to the handle
/// it publishes, and revokes it before dropping the ownership that makes the
/// handle authoritative. Revocation is monotonic: nothing restores it, and
/// [NewOwnerResetJournal.load] never reissues authority.
final class NewOwnerResetJournalLease {
  bool get isRevoked => _revoked;

  var _revoked = false;

  void revoke() {
    _revoked = true;
  }
}

final class NewOwnerResetJournalLeaseRevokedException implements Exception {
  const NewOwnerResetJournalLeaseRevokedException(this.message);

  final String message;

  @override
  String toString() => 'NewOwnerResetJournalLeaseRevokedException: $message';
}

final class NewOwnerResetJournalWriteException implements Exception {
  const NewOwnerResetJournalWriteException(this.message);

  final String message;

  @override
  String toString() => 'NewOwnerResetJournalWriteException: $message';
}

/// A persistence failure whose durable outcome is unknown: the previous state,
/// the requested state, and an unreadable file are all still possible.
///
/// Callers must treat this as uncertain, never as absent or as a clean failure.
final class NewOwnerResetJournalIndeterminateWriteException
    extends NewOwnerResetJournalWriteException {
  const NewOwnerResetJournalIndeterminateWriteException(super.message);

  @override
  String toString() =>
      'NewOwnerResetJournalIndeterminateWriteException: $message';
}

abstract interface class NewOwnerResetJournalStore {
  NewOwnerResetJournalReadResult read();
  void write(NewOwnerResetJournalRecord record);
  void delete();
}

/// Filesystem seam for [NewOwnerResetJournalFileStore].
///
/// Production uses [IoNewOwnerResetJournalFileOperations]; tests inject staged
/// write, flush, close, rename and delete faults at the exact syscall boundary
/// the store depends on.
abstract interface class NewOwnerResetJournalFileOperations {
  FileSystemEntityType typeSync(String path);
  List<int> readBytesSync(String path);
  int lengthSync(String path);
  NewOwnerResetJournalStagedWrite openStaged(String path);
  void renameSync(String from, String to);
  void deleteSync(String path);
}

abstract interface class NewOwnerResetJournalStagedWrite {
  void writeBytes(List<int> bytes);
  void flush();
  void close();
}

final class IoNewOwnerResetJournalFileOperations
    implements NewOwnerResetJournalFileOperations {
  const IoNewOwnerResetJournalFileOperations();

  @override
  FileSystemEntityType typeSync(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false);

  @override
  List<int> readBytesSync(String path) => File(path).readAsBytesSync();

  @override
  int lengthSync(String path) => File(path).lengthSync();

  @override
  NewOwnerResetJournalStagedWrite openStaged(String path) =>
      _IoNewOwnerResetJournalStagedWrite(
        File(path).openSync(mode: FileMode.writeOnly),
      );

  @override
  void renameSync(String from, String to) => File(from).renameSync(to);

  @override
  void deleteSync(String path) => File(path).deleteSync();
}

final class _IoNewOwnerResetJournalStagedWrite
    implements NewOwnerResetJournalStagedWrite {
  _IoNewOwnerResetJournalStagedWrite(this._handle);

  final RandomAccessFile _handle;

  @override
  void writeBytes(List<int> bytes) => _handle.writeFromSync(bytes);

  @override
  void flush() => _handle.flushSync();

  @override
  void close() => _handle.closeSync();
}

final class NewOwnerResetJournalFileStore implements NewOwnerResetJournalStore {
  NewOwnerResetJournalFileStore(
    this.file, {
    this.operations = const IoNewOwnerResetJournalFileOperations(),
  });

  final File file;
  final NewOwnerResetJournalFileOperations operations;

  @override
  NewOwnerResetJournalReadResult read() {
    final type = operations.typeSync(file.path);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      return NewOwnerResetJournalUnreadable(
        'journal path is a $type, not a readable regular file',
      );
    }
    final List<int> bytes;
    try {
      bytes = operations.readBytesSync(file.path);
    } on PathNotFoundException {
      if (type == FileSystemEntityType.notFound) {
        return const NewOwnerResetJournalAbsent();
      }
      return const NewOwnerResetJournalUnreadable(
        'journal file disappeared while being read',
      );
    } on FileSystemException catch (error) {
      return NewOwnerResetJournalUnreadable(
        'journal file could not be read: ${error.message}',
      );
    }
    final String raw;
    try {
      raw = utf8.decode(bytes);
    } on FormatException catch (error) {
      return NewOwnerResetJournalUnreadable(
        'journal content is not valid UTF-8: ${error.message}',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      return NewOwnerResetJournalUnreadable(
        'journal state is not valid JSON: ${error.message}',
      );
    }
    try {
      return NewOwnerResetJournalPresent(
        NewOwnerResetJournalRecord.fromJson(decoded),
      );
    } on FormatException catch (error) {
      return NewOwnerResetJournalUnreadable(error.message);
    }
  }

  @override
  void write(NewOwnerResetJournalRecord record) {
    final payload = utf8.encode(jsonEncode(record.toJson()));
    final staged = File('${file.path}.tmp');
    _requireReplaceablePath(file, 'journal');
    _requireReplaceablePath(staged, 'journal staging');
    final previous = _capturePriorState();

    FileSystemException? failure;
    NewOwnerResetJournalStagedWrite? open;
    try {
      open = operations.openStaged(staged.path);
      open.writeBytes(payload);
      open.flush();
      open.close();
      open = null;
      operations.renameSync(staged.path, file.path);
      return;
    } on FileSystemException catch (error) {
      failure = error;
    } finally {
      if (open != null) {
        try {
          open.close();
        } on FileSystemException {
          failure ??= const FileSystemException(
            'journal staging file could not be closed',
          );
        }
      }
    }
    _discardStagedQuietly(staged);
    switch (_observeReplacement(record, previous)) {
      case _JournalWriteOutcome.committed:
        return;
      case _JournalWriteOutcome.rejected:
        throw NewOwnerResetJournalWriteException(
          'journal could not be written: ${_describe(failure)}',
        );
      case _JournalWriteOutcome.indeterminate:
        throw NewOwnerResetJournalIndeterminateWriteException(
          'journal write outcome is unknown: ${_describe(failure)}',
        );
    }
  }

  @override
  void delete() {
    _requireReplaceablePath(file, 'journal');
    FileSystemException? failure;
    try {
      operations.deleteSync(file.path);
      return;
    } on PathNotFoundException catch (error) {
      failure = error;
    } on FileSystemException catch (error) {
      failure = error;
    }
    switch (_observePresence()) {
      case _JournalPresence.absent:
        return;
      case _JournalPresence.unknown:
        throw NewOwnerResetJournalIndeterminateWriteException(
          'journal deletion outcome is unknown: ${_describe(failure)}',
        );
      case _JournalPresence.present:
        break;
    }
    switch (read()) {
      case NewOwnerResetJournalPresent():
        throw NewOwnerResetJournalWriteException(
          'journal could not be deleted: ${_describe(failure)}',
        );
      case NewOwnerResetJournalAbsent():
      case NewOwnerResetJournalUnreadable():
        throw NewOwnerResetJournalIndeterminateWriteException(
          'journal deletion left unreadable recovery state: '
          '${_describe(failure)}',
        );
    }
  }

  /// The durable record this owner observed immediately before staging a
  /// replacement.
  ///
  /// Returns `null` for an absent journal and never stages anything when the
  /// current marker cannot be read, so unknown recovery state is not
  /// overwritten.
  NewOwnerResetJournalRecord? _capturePriorState() {
    switch (read()) {
      case NewOwnerResetJournalAbsent():
        return null;
      case NewOwnerResetJournalPresent(:final record):
        return record;
      case NewOwnerResetJournalUnreadable(:final reason):
        throw NewOwnerResetJournalWriteException(
          'journal state cannot be read ($reason); refusing to overwrite '
          'unknown recovery state',
        );
    }
  }

  /// Classifies a failed replace against the record it tried to publish and
  /// the durable state captured before staging.
  ///
  /// Only the intended record is a commit; only the prior record, or continued
  /// absence with no prior marker, is a rejection. Any other readable content,
  /// a lost marker, or unreadable state is indeterminate.
  _JournalWriteOutcome _observeReplacement(
    NewOwnerResetJournalRecord intended,
    NewOwnerResetJournalRecord? previous,
  ) {
    switch (read()) {
      case NewOwnerResetJournalPresent(:final record):
        if (_matchesRecord(record, intended)) {
          return _JournalWriteOutcome.committed;
        }
        if (previous != null && _matchesRecord(record, previous)) {
          return _JournalWriteOutcome.rejected;
        }
        return _JournalWriteOutcome.indeterminate;
      case NewOwnerResetJournalAbsent():
        return previous == null
            ? _JournalWriteOutcome.rejected
            : _JournalWriteOutcome.indeterminate;
      case NewOwnerResetJournalUnreadable():
        return _JournalWriteOutcome.indeterminate;
    }
  }

  _JournalPresence _observePresence() {
    try {
      operations.lengthSync(file.path);
    } on PathNotFoundException {
      return _JournalPresence.absent;
    } on FileSystemException {
      return _JournalPresence.unknown;
    }
    return _JournalPresence.present;
  }
}

enum _JournalWriteOutcome { committed, rejected, indeterminate }

enum _JournalPresence { absent, present, unknown }

String _describe(FileSystemException? error) =>
    error?.message ?? 'no filesystem error was reported';

final class NewOwnerResetJournal {
  NewOwnerResetJournal(
    this._store, {
    required String processSessionId,
    required NewOwnerResetJournalLease authority,
  }) : _processSessionId = processSessionId,
       _lease = authority {
    if (processSessionId.trim().isEmpty) {
      throw ArgumentError.value(
        processSessionId,
        'processSessionId',
        'must be a non-empty opaque process-session identity',
      );
    }
  }

  final NewOwnerResetJournalStore _store;
  final String _processSessionId;
  final NewOwnerResetJournalLease _lease;
  var _loaded = false;
  var _unreadable = false;
  var _durableStateUnknown = false;
  NewOwnerResetJournalRecord? _record;

  NewOwnerResetJournalRecord? get record => _record;

  /// True when a persistence operation failed without establishing whether it
  /// committed. No further mutation is allowed until [load] succeeds again.
  bool get durableStateUnknown => _durableStateUnknown;

  String get processSessionId => _processSessionId;

  NewOwnerResetJournalReadResult load() {
    final result = _store.read();
    switch (result) {
      case NewOwnerResetJournalAbsent():
        _record = null;
        _unreadable = false;
      case NewOwnerResetJournalPresent(:final record):
        _record = record;
        _unreadable = false;
      case NewOwnerResetJournalUnreadable():
        _record = null;
        _unreadable = true;
    }
    _loaded = true;
    _durableStateUnknown = false;
    return result;
  }

  void beginReset({required NewOwnerResetRetainedConfiguration retained}) {
    _requireModifiable();
    final existing = _record;
    if (existing != null) {
      throw NewOwnerResetJournalStateException(
        'a reset journal already exists in state ${existing.state.name}; '
        'resume it instead of starting a new reset',
      );
    }
    _publish(
      NewOwnerResetJournalRecord.resetting(
        stage: NewOwnerResetStage.deletion,
        retained: retained,
      ),
    );
  }

  void completeStage(NewOwnerResetStage stage) {
    final current = _requireRecord();
    if (current.state != NewOwnerResetState.resetting) {
      throw NewOwnerResetJournalStateException(
        'stage ${stage.name} cannot complete while the journal is '
        '${current.state.name}',
      );
    }
    final outstanding = current.stage!;
    if (stage.index < outstanding.index) return;
    if (stage.index > outstanding.index) {
      throw NewOwnerResetJournalStateException(
        'cannot complete ${stage.name} while ${outstanding.name} is '
        'outstanding',
      );
    }
    final next = stage == NewOwnerResetStage.verification
        ? null
        : NewOwnerResetStage.values[stage.index + 1];
    _publish(
      next == null
          ? NewOwnerResetJournalRecord.ready(retained: current.retained)
          : NewOwnerResetJournalRecord.resetting(
              stage: next,
              retained: current.retained,
            ),
    );
  }

  void acknowledgeHandoff() {
    final current = _requireRecord();
    if (current.state != NewOwnerResetState.ready) {
      throw NewOwnerResetJournalStateException(
        'handoff can only be acknowledged from '
        '${NewOwnerResetState.ready.name}, not ${current.state.name}',
      );
    }
    _publish(
      NewOwnerResetJournalRecord.handoffArmed(
        retained: current.retained,
        armedBySessionId: _processSessionId,
      ),
    );
  }

  void consumeHandoff() {
    final current = _requireRecord();
    if (current.state != NewOwnerResetState.handoffArmed) {
      throw NewOwnerResetJournalStateException(
        'no armed handoff to consume (state ${current.state.name})',
      );
    }
    if (current.armedBySessionId == _processSessionId) {
      throw NewOwnerResetJournalStateException(
        'the acknowledging process session must not consume its own handoff',
      );
    }
    _requireUndisputedDurableState();
    try {
      _store.delete();
    } on NewOwnerResetJournalIndeterminateWriteException {
      _durableStateUnknown = true;
      rethrow;
    }
    _record = null;
  }

  void _publish(NewOwnerResetJournalRecord record) {
    final encoded = jsonEncode(record.toJson());
    final NewOwnerResetJournalRecord reparsed;
    try {
      reparsed = NewOwnerResetJournalRecord.fromJson(jsonDecode(encoded));
    } on FormatException catch (error) {
      throw NewOwnerResetJournalWriteException(
        'journal record failed schema validation before any write: '
        '${error.message}',
      );
    }
    if (jsonEncode(reparsed.toJson()) != encoded) {
      throw const NewOwnerResetJournalWriteException(
        'journal record is not losslessly representable',
      );
    }
    _requireUndisputedDurableState();
    try {
      _store.write(record);
    } on NewOwnerResetJournalIndeterminateWriteException {
      _durableStateUnknown = true;
      rethrow;
    }
    _record = record;
  }

  /// Refuses to advance state this owner can no longer prove it owns.
  void _requireUndisputedDurableState() {
    final expected = _record;
    final result = _store.read();
    switch (result) {
      case NewOwnerResetJournalPresent(:final record):
        if (expected != null && _matchesRecord(record, expected)) {
          return;
        }
      case NewOwnerResetJournalAbsent():
        if (expected == null) return;
      case NewOwnerResetJournalUnreadable(:final reason):
        throw NewOwnerResetJournalWriteException(
          'the journal on disk cannot be read ($reason); refusing to change '
          'recovery state',
        );
    }
    throw const NewOwnerResetJournalWriteException(
      'the journal changed on disk since this owner loaded it; refusing to '
      'change recovery state without reloading it',
    );
  }

  void _requireModifiable() {
    if (_lease.isRevoked) {
      throw const NewOwnerResetJournalLeaseRevokedException(
        'the owning composition released this journal handle, so it cannot '
        'change recovery state',
      );
    }
    if (!_loaded) {
      throw const NewOwnerResetJournalStateException(
        'load() must succeed before the journal is modified',
      );
    }
    if (_durableStateUnknown) {
      throw const NewOwnerResetJournalStateException(
        'the durable journal state is unknown; reload before changing '
        'recovery state',
      );
    }
    if (_unreadable) {
      throw const NewOwnerResetJournalStateException(
        'the journal is unreadable; refusing to overwrite recovery state',
      );
    }
  }

  NewOwnerResetJournalRecord _requireRecord() {
    _requireModifiable();
    final current = _record;
    if (current == null) {
      throw const NewOwnerResetJournalStateException('no reset journal exists');
    }
    return current;
  }
}

String _encodeRecord(NewOwnerResetJournalRecord record) =>
    jsonEncode(record.toJson());

bool _matchesRecord(
  NewOwnerResetJournalRecord candidate,
  NewOwnerResetJournalRecord expected,
) => _encodeRecord(candidate) == _encodeRecord(expected);

FileSystemEntityType _requireReplaceablePath(File target, String label) {
  final type = FileSystemEntity.typeSync(target.path, followLinks: false);
  if (type == FileSystemEntityType.file ||
      type == FileSystemEntityType.notFound) {
    return type;
  }
  throw NewOwnerResetJournalWriteException(
    '$label path is a $type, not a regular file or an absent file',
  );
}

void _discardStagedQuietly(File staged) {
  try {
    if (FileSystemEntity.typeSync(staged.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return;
    }
    staged.deleteSync();
  } on FileSystemException {
    return;
  }
}

void _rejectUnknownKeys(
  Map<String, dynamic> json,
  Set<String> allowed,
  String label,
) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('$label has unexpected field "$key"');
    }
  }
}

void _requireKeys(
  Map<String, dynamic> json,
  Set<String> required,
  String label,
) {
  for (final key in required) {
    if (!json.containsKey(key)) {
      throw FormatException('$label is missing field "$key"');
    }
  }
}

String _requireNonEmptyString(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('journal field "$field" must be a non-empty string');
  }
  return value;
}

String? _optionalNonEmptyString(Object? value, String field) {
  if (value == null) return null;
  return _requireNonEmptyString(value, field);
}

T _enumByName<T extends Enum>(List<T> values, Object? name, String label) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('unknown journal $label "$name"');
}
