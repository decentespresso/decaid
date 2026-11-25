import 'dart:convert';
import 'dart:io';

const int newOwnerResetJournalSchemaVersion = 1;

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

final class NewOwnerResetJournalWriteException implements Exception {
  const NewOwnerResetJournalWriteException(this.message);

  final String message;

  @override
  String toString() => 'NewOwnerResetJournalWriteException: $message';
}

abstract interface class NewOwnerResetJournalStore {
  NewOwnerResetJournalReadResult read();
  void write(NewOwnerResetJournalRecord record);
  void delete();
}

final class NewOwnerResetJournalFileStore implements NewOwnerResetJournalStore {
  NewOwnerResetJournalFileStore(this.file);

  final File file;

  @override
  NewOwnerResetJournalReadResult read() {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      return NewOwnerResetJournalUnreadable(
        'journal path is a $type, not a readable regular file',
      );
    }
    final String raw;
    try {
      raw = file.readAsStringSync();
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
    try {
      final handle = staged.openSync(mode: FileMode.writeOnly);
      try {
        handle.writeFromSync(payload);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      staged.renameSync(file.path);
    } on FileSystemException catch (error) {
      _discardStagedQuietly(staged);
      throw NewOwnerResetJournalWriteException(
        'journal could not be written: ${error.message}',
      );
    }
  }

  @override
  void delete() {
    _requireReplaceablePath(file, 'journal');
    try {
      file.deleteSync();
    } on PathNotFoundException {
      _requireJournalGone();
    } on FileSystemException catch (error) {
      throw NewOwnerResetJournalWriteException(
        'journal could not be deleted: ${error.message}',
      );
    }
  }

  void _requireJournalGone() {
    try {
      file.lengthSync();
    } on PathNotFoundException {
      return;
    } on FileSystemException catch (error) {
      throw NewOwnerResetJournalWriteException(
        'journal could not be deleted: ${error.message}',
      );
    }
    throw const NewOwnerResetJournalWriteException(
      'journal could not be deleted: the journal file is still present',
    );
  }
}

final class NewOwnerResetJournal {
  NewOwnerResetJournal(this._store, {required String processSessionId})
    : _processSessionId = processSessionId {
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
  var _loaded = false;
  var _unreadable = false;
  NewOwnerResetJournalRecord? _record;

  NewOwnerResetJournalRecord? get record => _record;

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
    _store.delete();
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
    _store.write(record);
    _record = record;
  }

  void _requireModifiable() {
    if (!_loaded) {
      throw const NewOwnerResetJournalStateException(
        'load() must succeed before the journal is modified',
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
