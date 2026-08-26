// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $BeansTable extends Beans with TableInfo<$BeansTable, Bean> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BeansTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roasterMeta = const VerificationMeta(
    'roaster',
  );
  @override
  late final GeneratedColumn<String> roaster = GeneratedColumn<String>(
    'roaster',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _speciesMeta = const VerificationMeta(
    'species',
  );
  @override
  late final GeneratedColumn<String> species = GeneratedColumn<String>(
    'species',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _decafMeta = const VerificationMeta('decaf');
  @override
  late final GeneratedColumn<bool> decaf = GeneratedColumn<bool>(
    'decaf',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("decaf" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _decafProcessMeta = const VerificationMeta(
    'decafProcess',
  );
  @override
  late final GeneratedColumn<String> decafProcess = GeneratedColumn<String>(
    'decaf_process',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _countryMeta = const VerificationMeta(
    'country',
  );
  @override
  late final GeneratedColumn<String> country = GeneratedColumn<String>(
    'country',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _regionMeta = const VerificationMeta('region');
  @override
  late final GeneratedColumn<String> region = GeneratedColumn<String>(
    'region',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _producerMeta = const VerificationMeta(
    'producer',
  );
  @override
  late final GeneratedColumn<String> producer = GeneratedColumn<String>(
    'producer',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<List<String>?, String> variety =
      GeneratedColumn<String>(
        'variety',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<List<String>?>($BeansTable.$convertervariety);
  @override
  late final GeneratedColumnWithTypeConverter<List<int>?, String> altitude =
      GeneratedColumn<String>(
        'altitude',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<List<int>?>($BeansTable.$converteraltitude);
  static const VerificationMeta _processingMeta = const VerificationMeta(
    'processing',
  );
  @override
  late final GeneratedColumn<String> processing = GeneratedColumn<String>(
    'processing',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _archivedMeta = const VerificationMeta(
    'archived',
  );
  @override
  late final GeneratedColumn<bool> archived = GeneratedColumn<bool>(
    'archived',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("archived" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String>
  extras = GeneratedColumn<String>(
    'extras',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  ).withConverter<Map<String, dynamic>?>($BeansTable.$converterextras);
  @override
  List<GeneratedColumn> get $columns => [
    id,
    roaster,
    name,
    species,
    decaf,
    decafProcess,
    country,
    region,
    producer,
    variety,
    altitude,
    processing,
    notes,
    archived,
    createdAt,
    updatedAt,
    extras,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'beans';
  @override
  VerificationContext validateIntegrity(
    Insertable<Bean> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('roaster')) {
      context.handle(
        _roasterMeta,
        roaster.isAcceptableOrUnknown(data['roaster']!, _roasterMeta),
      );
    } else if (isInserting) {
      context.missing(_roasterMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('species')) {
      context.handle(
        _speciesMeta,
        species.isAcceptableOrUnknown(data['species']!, _speciesMeta),
      );
    }
    if (data.containsKey('decaf')) {
      context.handle(
        _decafMeta,
        decaf.isAcceptableOrUnknown(data['decaf']!, _decafMeta),
      );
    }
    if (data.containsKey('decaf_process')) {
      context.handle(
        _decafProcessMeta,
        decafProcess.isAcceptableOrUnknown(
          data['decaf_process']!,
          _decafProcessMeta,
        ),
      );
    }
    if (data.containsKey('country')) {
      context.handle(
        _countryMeta,
        country.isAcceptableOrUnknown(data['country']!, _countryMeta),
      );
    }
    if (data.containsKey('region')) {
      context.handle(
        _regionMeta,
        region.isAcceptableOrUnknown(data['region']!, _regionMeta),
      );
    }
    if (data.containsKey('producer')) {
      context.handle(
        _producerMeta,
        producer.isAcceptableOrUnknown(data['producer']!, _producerMeta),
      );
    }
    if (data.containsKey('processing')) {
      context.handle(
        _processingMeta,
        processing.isAcceptableOrUnknown(data['processing']!, _processingMeta),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('archived')) {
      context.handle(
        _archivedMeta,
        archived.isAcceptableOrUnknown(data['archived']!, _archivedMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Bean map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Bean(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      roaster: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}roaster'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      species: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}species'],
      ),
      decaf: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}decaf'],
      )!,
      decafProcess: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}decaf_process'],
      ),
      country: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}country'],
      ),
      region: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}region'],
      ),
      producer: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}producer'],
      ),
      variety: $BeansTable.$convertervariety.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}variety'],
        ),
      ),
      altitude: $BeansTable.$converteraltitude.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}altitude'],
        ),
      ),
      processing: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}processing'],
      ),
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      archived: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}archived'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      extras: $BeansTable.$converterextras.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}extras'],
        ),
      ),
    );
  }

  @override
  $BeansTable createAlias(String alias) {
    return $BeansTable(attachedDatabase, alias);
  }

  static TypeConverter<List<String>?, String?> $convertervariety =
      const NullableStringListConverter();
  static TypeConverter<List<int>?, String?> $converteraltitude =
      const NullableIntListConverter();
  static TypeConverter<Map<String, dynamic>?, String?> $converterextras =
      const NullableJsonMapConverter();
}

class Bean extends DataClass implements Insertable<Bean> {
  final String id;
  final String roaster;
  final String name;
  final String? species;
  final bool decaf;
  final String? decafProcess;
  final String? country;
  final String? region;
  final String? producer;
  final List<String>? variety;
  final List<int>? altitude;
  final String? processing;
  final String? notes;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? extras;
  const Bean({
    required this.id,
    required this.roaster,
    required this.name,
    this.species,
    required this.decaf,
    this.decafProcess,
    this.country,
    this.region,
    this.producer,
    this.variety,
    this.altitude,
    this.processing,
    this.notes,
    required this.archived,
    required this.createdAt,
    required this.updatedAt,
    this.extras,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['roaster'] = Variable<String>(roaster);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || species != null) {
      map['species'] = Variable<String>(species);
    }
    map['decaf'] = Variable<bool>(decaf);
    if (!nullToAbsent || decafProcess != null) {
      map['decaf_process'] = Variable<String>(decafProcess);
    }
    if (!nullToAbsent || country != null) {
      map['country'] = Variable<String>(country);
    }
    if (!nullToAbsent || region != null) {
      map['region'] = Variable<String>(region);
    }
    if (!nullToAbsent || producer != null) {
      map['producer'] = Variable<String>(producer);
    }
    if (!nullToAbsent || variety != null) {
      map['variety'] = Variable<String>(
        $BeansTable.$convertervariety.toSql(variety),
      );
    }
    if (!nullToAbsent || altitude != null) {
      map['altitude'] = Variable<String>(
        $BeansTable.$converteraltitude.toSql(altitude),
      );
    }
    if (!nullToAbsent || processing != null) {
      map['processing'] = Variable<String>(processing);
    }
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    map['archived'] = Variable<bool>(archived);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || extras != null) {
      map['extras'] = Variable<String>(
        $BeansTable.$converterextras.toSql(extras),
      );
    }
    return map;
  }

  BeansCompanion toCompanion(bool nullToAbsent) {
    return BeansCompanion(
      id: Value(id),
      roaster: Value(roaster),
      name: Value(name),
      species: species == null && nullToAbsent
          ? const Value.absent()
          : Value(species),
      decaf: Value(decaf),
      decafProcess: decafProcess == null && nullToAbsent
          ? const Value.absent()
          : Value(decafProcess),
      country: country == null && nullToAbsent
          ? const Value.absent()
          : Value(country),
      region: region == null && nullToAbsent
          ? const Value.absent()
          : Value(region),
      producer: producer == null && nullToAbsent
          ? const Value.absent()
          : Value(producer),
      variety: variety == null && nullToAbsent
          ? const Value.absent()
          : Value(variety),
      altitude: altitude == null && nullToAbsent
          ? const Value.absent()
          : Value(altitude),
      processing: processing == null && nullToAbsent
          ? const Value.absent()
          : Value(processing),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      archived: Value(archived),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      extras: extras == null && nullToAbsent
          ? const Value.absent()
          : Value(extras),
    );
  }

  factory Bean.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Bean(
      id: serializer.fromJson<String>(json['id']),
      roaster: serializer.fromJson<String>(json['roaster']),
      name: serializer.fromJson<String>(json['name']),
      species: serializer.fromJson<String?>(json['species']),
      decaf: serializer.fromJson<bool>(json['decaf']),
      decafProcess: serializer.fromJson<String?>(json['decafProcess']),
      country: serializer.fromJson<String?>(json['country']),
      region: serializer.fromJson<String?>(json['region']),
      producer: serializer.fromJson<String?>(json['producer']),
      variety: serializer.fromJson<List<String>?>(json['variety']),
      altitude: serializer.fromJson<List<int>?>(json['altitude']),
      processing: serializer.fromJson<String?>(json['processing']),
      notes: serializer.fromJson<String?>(json['notes']),
      archived: serializer.fromJson<bool>(json['archived']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      extras: serializer.fromJson<Map<String, dynamic>?>(json['extras']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'roaster': serializer.toJson<String>(roaster),
      'name': serializer.toJson<String>(name),
      'species': serializer.toJson<String?>(species),
      'decaf': serializer.toJson<bool>(decaf),
      'decafProcess': serializer.toJson<String?>(decafProcess),
      'country': serializer.toJson<String?>(country),
      'region': serializer.toJson<String?>(region),
      'producer': serializer.toJson<String?>(producer),
      'variety': serializer.toJson<List<String>?>(variety),
      'altitude': serializer.toJson<List<int>?>(altitude),
      'processing': serializer.toJson<String?>(processing),
      'notes': serializer.toJson<String?>(notes),
      'archived': serializer.toJson<bool>(archived),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'extras': serializer.toJson<Map<String, dynamic>?>(extras),
    };
  }

  Bean copyWith({
    String? id,
    String? roaster,
    String? name,
    Value<String?> species = const Value.absent(),
    bool? decaf,
    Value<String?> decafProcess = const Value.absent(),
    Value<String?> country = const Value.absent(),
    Value<String?> region = const Value.absent(),
    Value<String?> producer = const Value.absent(),
    Value<List<String>?> variety = const Value.absent(),
    Value<List<int>?> altitude = const Value.absent(),
    Value<String?> processing = const Value.absent(),
    Value<String?> notes = const Value.absent(),
    bool? archived,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<Map<String, dynamic>?> extras = const Value.absent(),
  }) => Bean(
    id: id ?? this.id,
    roaster: roaster ?? this.roaster,
    name: name ?? this.name,
    species: species.present ? species.value : this.species,
    decaf: decaf ?? this.decaf,
    decafProcess: decafProcess.present ? decafProcess.value : this.decafProcess,
    country: country.present ? country.value : this.country,
    region: region.present ? region.value : this.region,
    producer: producer.present ? producer.value : this.producer,
    variety: variety.present ? variety.value : this.variety,
    altitude: altitude.present ? altitude.value : this.altitude,
    processing: processing.present ? processing.value : this.processing,
    notes: notes.present ? notes.value : this.notes,
    archived: archived ?? this.archived,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    extras: extras.present ? extras.value : this.extras,
  );
  Bean copyWithCompanion(BeansCompanion data) {
    return Bean(
      id: data.id.present ? data.id.value : this.id,
      roaster: data.roaster.present ? data.roaster.value : this.roaster,
      name: data.name.present ? data.name.value : this.name,
      species: data.species.present ? data.species.value : this.species,
      decaf: data.decaf.present ? data.decaf.value : this.decaf,
      decafProcess: data.decafProcess.present
          ? data.decafProcess.value
          : this.decafProcess,
      country: data.country.present ? data.country.value : this.country,
      region: data.region.present ? data.region.value : this.region,
      producer: data.producer.present ? data.producer.value : this.producer,
      variety: data.variety.present ? data.variety.value : this.variety,
      altitude: data.altitude.present ? data.altitude.value : this.altitude,
      processing: data.processing.present
          ? data.processing.value
          : this.processing,
      notes: data.notes.present ? data.notes.value : this.notes,
      archived: data.archived.present ? data.archived.value : this.archived,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      extras: data.extras.present ? data.extras.value : this.extras,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Bean(')
          ..write('id: $id, ')
          ..write('roaster: $roaster, ')
          ..write('name: $name, ')
          ..write('species: $species, ')
          ..write('decaf: $decaf, ')
          ..write('decafProcess: $decafProcess, ')
          ..write('country: $country, ')
          ..write('region: $region, ')
          ..write('producer: $producer, ')
          ..write('variety: $variety, ')
          ..write('altitude: $altitude, ')
          ..write('processing: $processing, ')
          ..write('notes: $notes, ')
          ..write('archived: $archived, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('extras: $extras')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    roaster,
    name,
    species,
    decaf,
    decafProcess,
    country,
    region,
    producer,
    variety,
    altitude,
    processing,
    notes,
    archived,
    createdAt,
    updatedAt,
    extras,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Bean &&
          other.id == this.id &&
          other.roaster == this.roaster &&
          other.name == this.name &&
          other.species == this.species &&
          other.decaf == this.decaf &&
          other.decafProcess == this.decafProcess &&
          other.country == this.country &&
          other.region == this.region &&
          other.producer == this.producer &&
          other.variety == this.variety &&
          other.altitude == this.altitude &&
          other.processing == this.processing &&
          other.notes == this.notes &&
          other.archived == this.archived &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.extras == this.extras);
}

class BeansCompanion extends UpdateCompanion<Bean> {
  final Value<String> id;
  final Value<String> roaster;
  final Value<String> name;
  final Value<String?> species;
  final Value<bool> decaf;
  final Value<String?> decafProcess;
  final Value<String?> country;
  final Value<String?> region;
  final Value<String?> producer;
  final Value<List<String>?> variety;
  final Value<List<int>?> altitude;
  final Value<String?> processing;
  final Value<String?> notes;
  final Value<bool> archived;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<Map<String, dynamic>?> extras;
  final Value<int> rowid;
  const BeansCompanion({
    this.id = const Value.absent(),
    this.roaster = const Value.absent(),
    this.name = const Value.absent(),
    this.species = const Value.absent(),
    this.decaf = const Value.absent(),
    this.decafProcess = const Value.absent(),
    this.country = const Value.absent(),
    this.region = const Value.absent(),
    this.producer = const Value.absent(),
    this.variety = const Value.absent(),
    this.altitude = const Value.absent(),
    this.processing = const Value.absent(),
    this.notes = const Value.absent(),
    this.archived = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.extras = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BeansCompanion.insert({
    required String id,
    required String roaster,
    required String name,
    this.species = const Value.absent(),
    this.decaf = const Value.absent(),
    this.decafProcess = const Value.absent(),
    this.country = const Value.absent(),
    this.region = const Value.absent(),
    this.producer = const Value.absent(),
    this.variety = const Value.absent(),
    this.altitude = const Value.absent(),
    this.processing = const Value.absent(),
    this.notes = const Value.absent(),
    this.archived = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.extras = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       roaster = Value(roaster),
       name = Value(name),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Bean> custom({
    Expression<String>? id,
    Expression<String>? roaster,
    Expression<String>? name,
    Expression<String>? species,
    Expression<bool>? decaf,
    Expression<String>? decafProcess,
    Expression<String>? country,
    Expression<String>? region,
    Expression<String>? producer,
    Expression<String>? variety,
    Expression<String>? altitude,
    Expression<String>? processing,
    Expression<String>? notes,
    Expression<bool>? archived,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? extras,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (roaster != null) 'roaster': roaster,
      if (name != null) 'name': name,
      if (species != null) 'species': species,
      if (decaf != null) 'decaf': decaf,
      if (decafProcess != null) 'decaf_process': decafProcess,
      if (country != null) 'country': country,
      if (region != null) 'region': region,
      if (producer != null) 'producer': producer,
      if (variety != null) 'variety': variety,
      if (altitude != null) 'altitude': altitude,
      if (processing != null) 'processing': processing,
      if (notes != null) 'notes': notes,
      if (archived != null) 'archived': archived,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (extras != null) 'extras': extras,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BeansCompanion copyWith({
    Value<String>? id,
    Value<String>? roaster,
    Value<String>? name,
    Value<String?>? species,
    Value<bool>? decaf,
    Value<String?>? decafProcess,
    Value<String?>? country,
    Value<String?>? region,
    Value<String?>? producer,
    Value<List<String>?>? variety,
    Value<List<int>?>? altitude,
    Value<String?>? processing,
    Value<String?>? notes,
    Value<bool>? archived,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<Map<String, dynamic>?>? extras,
    Value<int>? rowid,
  }) {
    return BeansCompanion(
      id: id ?? this.id,
      roaster: roaster ?? this.roaster,
      name: name ?? this.name,
      species: species ?? this.species,
      decaf: decaf ?? this.decaf,
      decafProcess: decafProcess ?? this.decafProcess,
      country: country ?? this.country,
      region: region ?? this.region,
      producer: producer ?? this.producer,
      variety: variety ?? this.variety,
      altitude: altitude ?? this.altitude,
      processing: processing ?? this.processing,
      notes: notes ?? this.notes,
      archived: archived ?? this.archived,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      extras: extras ?? this.extras,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (roaster.present) {
      map['roaster'] = Variable<String>(roaster.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (species.present) {
      map['species'] = Variable<String>(species.value);
    }
    if (decaf.present) {
      map['decaf'] = Variable<bool>(decaf.value);
    }
    if (decafProcess.present) {
      map['decaf_process'] = Variable<String>(decafProcess.value);
    }
    if (country.present) {
      map['country'] = Variable<String>(country.value);
    }
    if (region.present) {
      map['region'] = Variable<String>(region.value);
    }
    if (producer.present) {
      map['producer'] = Variable<String>(producer.value);
    }
    if (variety.present) {
      map['variety'] = Variable<String>(
        $BeansTable.$convertervariety.toSql(variety.value),
      );
    }
    if (altitude.present) {
      map['altitude'] = Variable<String>(
        $BeansTable.$converteraltitude.toSql(altitude.value),
      );
    }
    if (processing.present) {
      map['processing'] = Variable<String>(processing.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (archived.present) {
      map['archived'] = Variable<bool>(archived.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (extras.present) {
      map['extras'] = Variable<String>(
        $BeansTable.$converterextras.toSql(extras.value),
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BeansCompanion(')
          ..write('id: $id, ')
          ..write('roaster: $roaster, ')
          ..write('name: $name, ')
          ..write('species: $species, ')
          ..write('decaf: $decaf, ')
          ..write('decafProcess: $decafProcess, ')
          ..write('country: $country, ')
          ..write('region: $region, ')
          ..write('producer: $producer, ')
          ..write('variety: $variety, ')
          ..write('altitude: $altitude, ')
          ..write('processing: $processing, ')
          ..write('notes: $notes, ')
          ..write('archived: $archived, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('extras: $extras, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BeanBatchesTable extends BeanBatches
    with TableInfo<$BeanBatchesTable, BeanBatche> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BeanBatchesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _beanIdMeta = const VerificationMeta('beanId');
  @override
  late final GeneratedColumn<String> beanId = GeneratedColumn<String>(
    'bean_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES beans (id)',
    ),
  );
  static const VerificationMeta _roastDateMeta = const VerificationMeta(
    'roastDate',
  );
  @override
  late final GeneratedColumn<DateTime> roastDate = GeneratedColumn<DateTime>(
    'roast_date',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _roastLevelMeta = const VerificationMeta(
    'roastLevel',
  );
  @override
  late final GeneratedColumn<String> roastLevel = GeneratedColumn<String>(
    'roast_level',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _harvestDateMeta = const VerificationMeta(
    'harvestDate',
  );
  @override
  late final GeneratedColumn<String> harvestDate = GeneratedColumn<String>(
    'harvest_date',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _qualityScoreMeta = const VerificationMeta(
    'qualityScore',
  );
  @override
  late final GeneratedColumn<double> qualityScore = GeneratedColumn<double>(
    'quality_score',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _priceMeta = const VerificationMeta('price');
  @override
  late final GeneratedColumn<double> price = GeneratedColumn<double>(
    'price',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _currencyMeta = const VerificationMeta(
    'currency',
  );
  @override
  late final GeneratedColumn<String> currency = GeneratedColumn<String>(
    'currency',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weightMeta = const VerificationMeta('weight');
  @override
  late final GeneratedColumn<double> weight = GeneratedColumn<double>(
    'weight',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weightRemainingMeta = const VerificationMeta(
    'weightRemaining',
  );
  @override
  late final GeneratedColumn<double> weightRemaining = GeneratedColumn<double>(
    'weight_remaining',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _buyDateMeta = const VerificationMeta(
    'buyDate',
  );
  @override
  late final GeneratedColumn<DateTime> buyDate = GeneratedColumn<DateTime>(
    'buy_date',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _openDateMeta = const VerificationMeta(
    'openDate',
  );
  @override
  late final GeneratedColumn<DateTime> openDate = GeneratedColumn<DateTime>(
    'open_date',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bestBeforeDateMeta = const VerificationMeta(
    'bestBeforeDate',
  );
  @override
  late final GeneratedColumn<DateTime> bestBeforeDate =
      GeneratedColumn<DateTime>(
        'best_before_date',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _freezeDateMeta = const VerificationMeta(
    'freezeDate',
  );
  @override
  late final GeneratedColumn<DateTime> freezeDate = GeneratedColumn<DateTime>(
    'freeze_date',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _unfreezeDateMeta = const VerificationMeta(
    'unfreezeDate',
  );
  @override
  late final GeneratedColumn<DateTime> unfreezeDate = GeneratedColumn<DateTime>(
    'unfreeze_date',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _frozenMeta = const VerificationMeta('frozen');
  @override
  late final GeneratedColumn<bool> frozen = GeneratedColumn<bool>(
    'frozen',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("frozen" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _archivedMeta = const VerificationMeta(
    'archived',
  );
  @override
  late final GeneratedColumn<bool> archived = GeneratedColumn<bool>(
    'archived',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("archived" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String>
  extras = GeneratedColumn<String>(
    'extras',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  ).withConverter<Map<String, dynamic>?>($BeanBatchesTable.$converterextras);
  @override
  List<GeneratedColumn> get $columns => [
    id,
    beanId,
    roastDate,
    roastLevel,
    harvestDate,
    qualityScore,
    price,
    currency,
    weight,
    weightRemaining,
    buyDate,
    openDate,
    bestBeforeDate,
    freezeDate,
    unfreezeDate,
    frozen,
    archived,
    notes,
    createdAt,
    updatedAt,
    extras,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bean_batches';
  @override
  VerificationContext validateIntegrity(
    Insertable<BeanBatche> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('bean_id')) {
      context.handle(
        _beanIdMeta,
        beanId.isAcceptableOrUnknown(data['bean_id']!, _beanIdMeta),
      );
    } else if (isInserting) {
      context.missing(_beanIdMeta);
    }
    if (data.containsKey('roast_date')) {
      context.handle(
        _roastDateMeta,
        roastDate.isAcceptableOrUnknown(data['roast_date']!, _roastDateMeta),
      );
    }
    if (data.containsKey('roast_level')) {
      context.handle(
        _roastLevelMeta,
        roastLevel.isAcceptableOrUnknown(data['roast_level']!, _roastLevelMeta),
      );
    }
    if (data.containsKey('harvest_date')) {
      context.handle(
        _harvestDateMeta,
        harvestDate.isAcceptableOrUnknown(
          data['harvest_date']!,
          _harvestDateMeta,
        ),
      );
    }
    if (data.containsKey('quality_score')) {
      context.handle(
        _qualityScoreMeta,
        qualityScore.isAcceptableOrUnknown(
          data['quality_score']!,
          _qualityScoreMeta,
        ),
      );
    }
    if (data.containsKey('price')) {
      context.handle(
        _priceMeta,
        price.isAcceptableOrUnknown(data['price']!, _priceMeta),
      );
    }
    if (data.containsKey('currency')) {
      context.handle(
        _currencyMeta,
        currency.isAcceptableOrUnknown(data['currency']!, _currencyMeta),
      );
    }
    if (data.containsKey('weight')) {
      context.handle(
        _weightMeta,
        weight.isAcceptableOrUnknown(data['weight']!, _weightMeta),
      );
    }
    if (data.containsKey('weight_remaining')) {
      context.handle(
        _weightRemainingMeta,
        weightRemaining.isAcceptableOrUnknown(
          data['weight_remaining']!,
          _weightRemainingMeta,
        ),
      );
    }
    if (data.containsKey('buy_date')) {
      context.handle(
        _buyDateMeta,
        buyDate.isAcceptableOrUnknown(data['buy_date']!, _buyDateMeta),
      );
    }
    if (data.containsKey('open_date')) {
      context.handle(
        _openDateMeta,
        openDate.isAcceptableOrUnknown(data['open_date']!, _openDateMeta),
      );
    }
    if (data.containsKey('best_before_date')) {
      context.handle(
        _bestBeforeDateMeta,
        bestBeforeDate.isAcceptableOrUnknown(
          data['best_before_date']!,
          _bestBeforeDateMeta,
        ),
      );
    }
    if (data.containsKey('freeze_date')) {
      context.handle(
        _freezeDateMeta,
        freezeDate.isAcceptableOrUnknown(data['freeze_date']!, _freezeDateMeta),
      );
    }
    if (data.containsKey('unfreeze_date')) {
      context.handle(
        _unfreezeDateMeta,
        unfreezeDate.isAcceptableOrUnknown(
          data['unfreeze_date']!,
          _unfreezeDateMeta,
        ),
      );
    }
    if (data.containsKey('frozen')) {
      context.handle(
        _frozenMeta,
        frozen.isAcceptableOrUnknown(data['frozen']!, _frozenMeta),
      );
    }
    if (data.containsKey('archived')) {
      context.handle(
        _archivedMeta,
        archived.isAcceptableOrUnknown(data['archived']!, _archivedMeta),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  BeanBatche map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BeanBatche(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      beanId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bean_id'],
      )!,
      roastDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}roast_date'],
      ),
      roastLevel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}roast_level'],
      ),
      harvestDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}harvest_date'],
      ),
      qualityScore: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}quality_score'],
      ),
      price: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}price'],
      ),
      currency: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}currency'],
      ),
      weight: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}weight'],
      ),
      weightRemaining: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}weight_remaining'],
      ),
      buyDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}buy_date'],
      ),
      openDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}open_date'],
      ),
      bestBeforeDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}best_before_date'],
      ),
      freezeDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}freeze_date'],
      ),
      unfreezeDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}unfreeze_date'],
      ),
      frozen: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}frozen'],
      )!,
      archived: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}archived'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      extras: $BeanBatchesTable.$converterextras.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}extras'],
        ),
      ),
    );
  }

  @override
  $BeanBatchesTable createAlias(String alias) {
    return $BeanBatchesTable(attachedDatabase, alias);
  }

  static TypeConverter<Map<String, dynamic>?, String?> $converterextras =
      const NullableJsonMapConverter();
}

class BeanBatche extends DataClass implements Insertable<BeanBatche> {
  final String id;
  final String beanId;
  final DateTime? roastDate;
  final String? roastLevel;
  final String? harvestDate;
  final double? qualityScore;
  final double? price;
  final String? currency;
  final double? weight;
  final double? weightRemaining;
  final DateTime? buyDate;
  final DateTime? openDate;
  final DateTime? bestBeforeDate;
  final DateTime? freezeDate;
  final DateTime? unfreezeDate;
  final bool frozen;
  final bool archived;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? extras;
  const BeanBatche({
    required this.id,
    required this.beanId,
    this.roastDate,
    this.roastLevel,
    this.harvestDate,
    this.qualityScore,
    this.price,
    this.currency,
    this.weight,
    this.weightRemaining,
    this.buyDate,
    this.openDate,
    this.bestBeforeDate,
    this.freezeDate,
    this.unfreezeDate,
    required this.frozen,
    required this.archived,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
    this.extras,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['bean_id'] = Variable<String>(beanId);
    if (!nullToAbsent || roastDate != null) {
      map['roast_date'] = Variable<DateTime>(roastDate);
    }
    if (!nullToAbsent || roastLevel != null) {
      map['roast_level'] = Variable<String>(roastLevel);
    }
    if (!nullToAbsent || harvestDate != null) {
      map['harvest_date'] = Variable<String>(harvestDate);
    }
    if (!nullToAbsent || qualityScore != null) {
      map['quality_score'] = Variable<double>(qualityScore);
    }
    if (!nullToAbsent || price != null) {
      map['price'] = Variable<double>(price);
    }
    if (!nullToAbsent || currency != null) {
      map['currency'] = Variable<String>(currency);
    }
    if (!nullToAbsent || weight != null) {
      map['weight'] = Variable<double>(weight);
    }
    if (!nullToAbsent || weightRemaining != null) {
      map['weight_remaining'] = Variable<double>(weightRemaining);
    }
    if (!nullToAbsent || buyDate != null) {
      map['buy_date'] = Variable<DateTime>(buyDate);
    }
    if (!nullToAbsent || openDate != null) {
      map['open_date'] = Variable<DateTime>(openDate);
    }
    if (!nullToAbsent || bestBeforeDate != null) {
      map['best_before_date'] = Variable<DateTime>(bestBeforeDate);
    }
    if (!nullToAbsent || freezeDate != null) {
      map['freeze_date'] = Variable<DateTime>(freezeDate);
    }
    if (!nullToAbsent || unfreezeDate != null) {
      map['unfreeze_date'] = Variable<DateTime>(unfreezeDate);
    }
    map['frozen'] = Variable<bool>(frozen);
    map['archived'] = Variable<bool>(archived);
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || extras != null) {
      map['extras'] = Variable<String>(
        $BeanBatchesTable.$converterextras.toSql(extras),
      );
    }
    return map;
  }

  BeanBatchesCompanion toCompanion(bool nullToAbsent) {
    return BeanBatchesCompanion(
      id: Value(id),
      beanId: Value(beanId),
      roastDate: roastDate == null && nullToAbsent
          ? const Value.absent()
          : Value(roastDate),
      roastLevel: roastLevel == null && nullToAbsent
          ? const Value.absent()
          : Value(roastLevel),
      harvestDate: harvestDate == null && nullToAbsent
          ? const Value.absent()
          : Value(harvestDate),
      qualityScore: qualityScore == null && nullToAbsent
          ? const Value.absent()
          : Value(qualityScore),
      price: price == null && nullToAbsent
          ? const Value.absent()
          : Value(price),
      currency: currency == null && nullToAbsent
          ? const Value.absent()
          : Value(currency),
      weight: weight == null && nullToAbsent
          ? const Value.absent()
          : Value(weight),
      weightRemaining: weightRemaining == null && nullToAbsent
          ? const Value.absent()
          : Value(weightRemaining),
      buyDate: buyDate == null && nullToAbsent
          ? const Value.absent()
          : Value(buyDate),
      openDate: openDate == null && nullToAbsent
          ? const Value.absent()
          : Value(openDate),
      bestBeforeDate: bestBeforeDate == null && nullToAbsent
          ? const Value.absent()
          : Value(bestBeforeDate),
      freezeDate: freezeDate == null && nullToAbsent
          ? const Value.absent()
          : Value(freezeDate),
      unfreezeDate: unfreezeDate == null && nullToAbsent
          ? const Value.absent()
          : Value(unfreezeDate),
      frozen: Value(frozen),
      archived: Value(archived),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      extras: extras == null && nullToAbsent
          ? const Value.absent()
          : Value(extras),
    );
  }

  factory BeanBatche.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BeanBatche(
      id: serializer.fromJson<String>(json['id']),
      beanId: serializer.fromJson<String>(json['beanId']),
      roastDate: serializer.fromJson<DateTime?>(json['roastDate']),
      roastLevel: serializer.fromJson<String?>(json['roastLevel']),
      harvestDate: serializer.fromJson<String?>(json['harvestDate']),
      qualityScore: serializer.fromJson<double?>(json['qualityScore']),
      price: serializer.fromJson<double?>(json['price']),
      currency: serializer.fromJson<String?>(json['currency']),
      weight: serializer.fromJson<double?>(json['weight']),
      weightRemaining: serializer.fromJson<double?>(json['weightRemaining']),
      buyDate: serializer.fromJson<DateTime?>(json['buyDate']),
      openDate: serializer.fromJson<DateTime?>(json['openDate']),
      bestBeforeDate: serializer.fromJson<DateTime?>(json['bestBeforeDate']),
      freezeDate: serializer.fromJson<DateTime?>(json['freezeDate']),
      unfreezeDate: serializer.fromJson<DateTime?>(json['unfreezeDate']),
      frozen: serializer.fromJson<bool>(json['frozen']),
      archived: serializer.fromJson<bool>(json['archived']),
      notes: serializer.fromJson<String?>(json['notes']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      extras: serializer.fromJson<Map<String, dynamic>?>(json['extras']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'beanId': serializer.toJson<String>(beanId),
      'roastDate': serializer.toJson<DateTime?>(roastDate),
      'roastLevel': serializer.toJson<String?>(roastLevel),
      'harvestDate': serializer.toJson<String?>(harvestDate),
      'qualityScore': serializer.toJson<double?>(qualityScore),
      'price': serializer.toJson<double?>(price),
      'currency': serializer.toJson<String?>(currency),
      'weight': serializer.toJson<double?>(weight),
      'weightRemaining': serializer.toJson<double?>(weightRemaining),
      'buyDate': serializer.toJson<DateTime?>(buyDate),
      'openDate': serializer.toJson<DateTime?>(openDate),
      'bestBeforeDate': serializer.toJson<DateTime?>(bestBeforeDate),
      'freezeDate': serializer.toJson<DateTime?>(freezeDate),
      'unfreezeDate': serializer.toJson<DateTime?>(unfreezeDate),
      'frozen': serializer.toJson<bool>(frozen),
      'archived': serializer.toJson<bool>(archived),
      'notes': serializer.toJson<String?>(notes),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'extras': serializer.toJson<Map<String, dynamic>?>(extras),
    };
  }

  BeanBatche copyWith({
    String? id,
    String? beanId,
    Value<DateTime?> roastDate = const Value.absent(),
    Value<String?> roastLevel = const Value.absent(),
    Value<String?> harvestDate = const Value.absent(),
    Value<double?> qualityScore = const Value.absent(),
    Value<double?> price = const Value.absent(),
    Value<String?> currency = const Value.absent(),
    Value<double?> weight = const Value.absent(),
    Value<double?> weightRemaining = const Value.absent(),
    Value<DateTime?> buyDate = const Value.absent(),
    Value<DateTime?> openDate = const Value.absent(),
    Value<DateTime?> bestBeforeDate = const Value.absent(),
    Value<DateTime?> freezeDate = const Value.absent(),
    Value<DateTime?> unfreezeDate = const Value.absent(),
    bool? frozen,
    bool? archived,
    Value<String?> notes = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<Map<String, dynamic>?> extras = const Value.absent(),
  }) => BeanBatche(
    id: id ?? this.id,
    beanId: beanId ?? this.beanId,
    roastDate: roastDate.present ? roastDate.value : this.roastDate,
    roastLevel: roastLevel.present ? roastLevel.value : this.roastLevel,
    harvestDate: harvestDate.present ? harvestDate.value : this.harvestDate,
    qualityScore: qualityScore.present ? qualityScore.value : this.qualityScore,
    price: price.present ? price.value : this.price,
    currency: currency.present ? currency.value : this.currency,
    weight: weight.present ? weight.value : this.weight,
    weightRemaining: weightRemaining.present
        ? weightRemaining.value
        : this.weightRemaining,
    buyDate: buyDate.present ? buyDate.value : this.buyDate,
    openDate: openDate.present ? openDate.value : this.openDate,
    bestBeforeDate: bestBeforeDate.present
        ? bestBeforeDate.value
        : this.bestBeforeDate,
    freezeDate: freezeDate.present ? freezeDate.value : this.freezeDate,
    unfreezeDate: unfreezeDate.present ? unfreezeDate.value : this.unfreezeDate,
    frozen: frozen ?? this.frozen,
    archived: archived ?? this.archived,
    notes: notes.present ? notes.value : this.notes,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    extras: extras.present ? extras.value : this.extras,
  );
  BeanBatche copyWithCompanion(BeanBatchesCompanion data) {
    return BeanBatche(
      id: data.id.present ? data.id.value : this.id,
      beanId: data.beanId.present ? data.beanId.value : this.beanId,
      roastDate: data.roastDate.present ? data.roastDate.value : this.roastDate,
      roastLevel: data.roastLevel.present
          ? data.roastLevel.value
          : this.roastLevel,
      harvestDate: data.harvestDate.present
          ? data.harvestDate.value
          : this.harvestDate,
      qualityScore: data.qualityScore.present
          ? data.qualityScore.value
          : this.qualityScore,
      price: data.price.present ? data.price.value : this.price,
      currency: data.currency.present ? data.currency.value : this.currency,
      weight: data.weight.present ? data.weight.value : this.weight,
      weightRemaining: data.weightRemaining.present
          ? data.weightRemaining.value
          : this.weightRemaining,
      buyDate: data.buyDate.present ? data.buyDate.value : this.buyDate,
      openDate: data.openDate.present ? data.openDate.value : this.openDate,
      bestBeforeDate: data.bestBeforeDate.present
          ? data.bestBeforeDate.value
          : this.bestBeforeDate,
      freezeDate: data.freezeDate.present
          ? data.freezeDate.value
          : this.freezeDate,
      unfreezeDate: data.unfreezeDate.present
          ? data.unfreezeDate.value
          : this.unfreezeDate,
      frozen: data.frozen.present ? data.frozen.value : this.frozen,
      archived: data.archived.present ? data.archived.value : this.archived,
      notes: data.notes.present ? data.notes.value : this.notes,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      extras: data.extras.present ? data.extras.value : this.extras,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BeanBatche(')
          ..write('id: $id, ')
          ..write('beanId: $beanId, ')
          ..write('roastDate: $roastDate, ')
          ..write('roastLevel: $roastLevel, ')
          ..write('harvestDate: $harvestDate, ')
          ..write('qualityScore: $qualityScore, ')
          ..write('price: $price, ')
          ..write('currency: $currency, ')
          ..write('weight: $weight, ')
          ..write('weightRemaining: $weightRemaining, ')
          ..write('buyDate: $buyDate, ')
          ..write('openDate: $openDate, ')
          ..write('bestBeforeDate: $bestBeforeDate, ')
          ..write('freezeDate: $freezeDate, ')
          ..write('unfreezeDate: $unfreezeDate, ')
          ..write('frozen: $frozen, ')
          ..write('archived: $archived, ')
          ..write('notes: $notes, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('extras: $extras')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    beanId,
    roastDate,
    roastLevel,
    harvestDate,
    qualityScore,
    price,
    currency,
    weight,
    weightRemaining,
    buyDate,
    openDate,
    bestBeforeDate,
    freezeDate,
    unfreezeDate,
    frozen,
    archived,
    notes,
    createdAt,
    updatedAt,
    extras,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BeanBatche &&
          other.id == this.id &&
          other.beanId == this.beanId &&
          other.roastDate == this.roastDate &&
          other.roastLevel == this.roastLevel &&
          other.harvestDate == this.harvestDate &&
          other.qualityScore == this.qualityScore &&
          other.price == this.price &&
          other.currency == this.currency &&
          other.weight == this.weight &&
          other.weightRemaining == this.weightRemaining &&
          other.buyDate == this.buyDate &&
          other.openDate == this.openDate &&
          other.bestBeforeDate == this.bestBeforeDate &&
          other.freezeDate == this.freezeDate &&
          other.unfreezeDate == this.unfreezeDate &&
          other.frozen == this.frozen &&
          other.archived == this.archived &&
          other.notes == this.notes &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.extras == this.extras);
}

class BeanBatchesCompanion extends UpdateCompanion<BeanBatche> {
  final Value<String> id;
  final Value<String> beanId;
  final Value<DateTime?> roastDate;
  final Value<String?> roastLevel;
  final Value<String?> harvestDate;
  final Value<double?> qualityScore;
  final Value<double?> price;
  final Value<String?> currency;
  final Value<double?> weight;
  final Value<double?> weightRemaining;
  final Value<DateTime?> buyDate;
  final Value<DateTime?> openDate;
  final Value<DateTime?> bestBeforeDate;
  final Value<DateTime?> freezeDate;
  final Value<DateTime?> unfreezeDate;
  final Value<bool> frozen;
  final Value<bool> archived;
  final Value<String?> notes;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<Map<String, dynamic>?> extras;
  final Value<int> rowid;
  const BeanBatchesCompanion({
    this.id = const Value.absent(),
    this.beanId = const Value.absent(),
    this.roastDate = const Value.absent(),
    this.roastLevel = const Value.absent(),
    this.harvestDate = const Value.absent(),
    this.qualityScore = const Value.absent(),
    this.price = const Value.absent(),
    this.currency = const Value.absent(),
    this.weight = const Value.absent(),
    this.weightRemaining = const Value.absent(),
    this.buyDate = const Value.absent(),
    this.openDate = const Value.absent(),
    this.bestBeforeDate = const Value.absent(),
    this.freezeDate = const Value.absent(),
    this.unfreezeDate = const Value.absent(),
    this.frozen = const Value.absent(),
    this.archived = const Value.absent(),
    this.notes = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.extras = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BeanBatchesCompanion.insert({
    required String id,
    required String beanId,
    this.roastDate = const Value.absent(),
    this.roastLevel = const Value.absent(),
    this.harvestDate = const Value.absent(),
    this.qualityScore = const Value.absent(),
    this.price = const Value.absent(),
    this.currency = const Value.absent(),
    this.weight = const Value.absent(),
    this.weightRemaining = const Value.absent(),
    this.buyDate = const Value.absent(),
    this.openDate = const Value.absent(),
    this.bestBeforeDate = const Value.absent(),
    this.freezeDate = const Value.absent(),
    this.unfreezeDate = const Value.absent(),
    this.frozen = const Value.absent(),
    this.archived = const Value.absent(),
    this.notes = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.extras = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       beanId = Value(beanId),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<BeanBatche> custom({
    Expression<String>? id,
    Expression<String>? beanId,
    Expression<DateTime>? roastDate,
    Expression<String>? roastLevel,
    Expression<String>? harvestDate,
    Expression<double>? qualityScore,
    Expression<double>? price,
    Expression<String>? currency,
    Expression<double>? weight,
    Expression<double>? weightRemaining,
    Expression<DateTime>? buyDate,
    Expression<DateTime>? openDate,
    Expression<DateTime>? bestBeforeDate,
    Expression<DateTime>? freezeDate,
    Expression<DateTime>? unfreezeDate,
    Expression<bool>? frozen,
    Expression<bool>? archived,
    Expression<String>? notes,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? extras,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (beanId != null) 'bean_id': beanId,
      if (roastDate != null) 'roast_date': roastDate,
      if (roastLevel != null) 'roast_level': roastLevel,
      if (harvestDate != null) 'harvest_date': harvestDate,
      if (qualityScore != null) 'quality_score': qualityScore,
      if (price != null) 'price': price,
      if (currency != null) 'currency': currency,
      if (weight != null) 'weight': weight,
      if (weightRemaining != null) 'weight_remaining': weightRemaining,
      if (buyDate != null) 'buy_date': buyDate,
      if (openDate != null) 'open_date': openDate,
      if (bestBeforeDate != null) 'best_before_date': bestBeforeDate,
      if (freezeDate != null) 'freeze_date': freezeDate,
      if (unfreezeDate != null) 'unfreeze_date': unfreezeDate,
      if (frozen != null) 'frozen': frozen,
      if (archived != null) 'archived': archived,
      if (notes != null) 'notes': notes,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (extras != null) 'extras': extras,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BeanBatchesCompanion copyWith({
    Value<String>? id,
    Value<String>? beanId,
    Value<DateTime?>? roastDate,
    Value<String?>? roastLevel,
    Value<String?>? harvestDate,
    Value<double?>? qualityScore,
    Value<double?>? price,
    Value<String?>? currency,
    Value<double?>? weight,
    Value<double?>? weightRemaining,
    Value<DateTime?>? buyDate,
    Value<DateTime?>? openDate,
    Value<DateTime?>? bestBeforeDate,
    Value<DateTime?>? freezeDate,
    Value<DateTime?>? unfreezeDate,
    Value<bool>? frozen,
    Value<bool>? archived,
    Value<String?>? notes,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<Map<String, dynamic>?>? extras,
    Value<int>? rowid,
  }) {
    return BeanBatchesCompanion(
      id: id ?? this.id,
      beanId: beanId ?? this.beanId,
      roastDate: roastDate ?? this.roastDate,
      roastLevel: roastLevel ?? this.roastLevel,
      harvestDate: harvestDate ?? this.harvestDate,
      qualityScore: qualityScore ?? this.qualityScore,
      price: price ?? this.price,
      currency: currency ?? this.currency,
      weight: weight ?? this.weight,
      weightRemaining: weightRemaining ?? this.weightRemaining,
      buyDate: buyDate ?? this.buyDate,
      openDate: openDate ?? this.openDate,
      bestBeforeDate: bestBeforeDate ?? this.bestBeforeDate,
      freezeDate: freezeDate ?? this.freezeDate,
      unfreezeDate: unfreezeDate ?? this.unfreezeDate,
      frozen: frozen ?? this.frozen,
      archived: archived ?? this.archived,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      extras: extras ?? this.extras,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (beanId.present) {
      map['bean_id'] = Variable<String>(beanId.value);
    }
    if (roastDate.present) {
      map['roast_date'] = Variable<DateTime>(roastDate.value);
    }
    if (roastLevel.present) {
      map['roast_level'] = Variable<String>(roastLevel.value);
    }
    if (harvestDate.present) {
      map['harvest_date'] = Variable<String>(harvestDate.value);
    }
    if (qualityScore.present) {
      map['quality_score'] = Variable<double>(qualityScore.value);
    }
    if (price.present) {
      map['price'] = Variable<double>(price.value);
    }
    if (currency.present) {
      map['currency'] = Variable<String>(currency.value);
    }
    if (weight.present) {
      map['weight'] = Variable<double>(weight.value);
    }
    if (weightRemaining.present) {
      map['weight_remaining'] = Variable<double>(weightRemaining.value);
    }
    if (buyDate.present) {
      map['buy_date'] = Variable<DateTime>(buyDate.value);
    }
    if (openDate.present) {
      map['open_date'] = Variable<DateTime>(openDate.value);
    }
    if (bestBeforeDate.present) {
      map['best_before_date'] = Variable<DateTime>(bestBeforeDate.value);
    }
    if (freezeDate.present) {
      map['freeze_date'] = Variable<DateTime>(freezeDate.value);
    }
    if (unfreezeDate.present) {
      map['unfreeze_date'] = Variable<DateTime>(unfreezeDate.value);
    }
    if (frozen.present) {
      map['frozen'] = Variable<bool>(frozen.value);
    }
    if (archived.present) {
      map['archived'] = Variable<bool>(archived.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (extras.present) {
      map['extras'] = Variable<String>(
        $BeanBatchesTable.$converterextras.toSql(extras.value),
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BeanBatchesCompanion(')
          ..write('id: $id, ')
          ..write('beanId: $beanId, ')
          ..write('roastDate: $roastDate, ')
          ..write('roastLevel: $roastLevel, ')
          ..write('harvestDate: $harvestDate, ')
          ..write('qualityScore: $qualityScore, ')
          ..write('price: $price, ')
          ..write('currency: $currency, ')
          ..write('weight: $weight, ')
          ..write('weightRemaining: $weightRemaining, ')
          ..write('buyDate: $buyDate, ')
          ..write('openDate: $openDate, ')
          ..write('bestBeforeDate: $bestBeforeDate, ')
          ..write('freezeDate: $freezeDate, ')
          ..write('unfreezeDate: $unfreezeDate, ')
          ..write('frozen: $frozen, ')
          ..write('archived: $archived, ')
          ..write('notes: $notes, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('extras: $extras, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GrindersTable extends Grinders with TableInfo<$GrindersTable, Grinder> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GrindersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
    'model',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _burrsMeta = const VerificationMeta('burrs');
  @override
  late final GeneratedColumn<String> burrs = GeneratedColumn<String>(
    'burrs',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _burrSizeMeta = const VerificationMeta(
    'burrSize',
  );
  @override
  late final GeneratedColumn<double> burrSize = GeneratedColumn<double>(
    'burr_size',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _burrTypeMeta = const VerificationMeta(
    'burrType',
  );
  @override
  late final GeneratedColumn<String> burrType = GeneratedColumn<String>(
    'burr_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _archivedMeta = const VerificationMeta(
    'archived',
  );
  @override
  late final GeneratedColumn<bool> archived = GeneratedColumn<bool>(
    'archived',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("archived" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _settingTypeMeta = const VerificationMeta(
    'settingType',
  );
  @override
  late final GeneratedColumn<String> settingType = GeneratedColumn<String>(
    'setting_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('numeric'),
  );
  @override
  late final GeneratedColumnWithTypeConverter<List<String>?, String>
  settingValues = GeneratedColumn<String>(
    'setting_values',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  ).withConverter<List<String>?>($GrindersTable.$convertersettingValues);
  static const VerificationMeta _settingSmallStepMeta = const VerificationMeta(
    'settingSmallStep',
  );
  @override
  late final GeneratedColumn<double> settingSmallStep = GeneratedColumn<double>(
    'setting_small_step',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _settingBigStepMeta = const VerificationMeta(
    'settingBigStep',
  );
  @override
  late final GeneratedColumn<double> settingBigStep = GeneratedColumn<double>(
    'setting_big_step',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rpmSmallStepMeta = const VerificationMeta(
    'rpmSmallStep',
  );
  @override
  late final GeneratedColumn<double> rpmSmallStep = GeneratedColumn<double>(
    'rpm_small_step',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rpmBigStepMeta = const VerificationMeta(
    'rpmBigStep',
  );
  @override
  late final GeneratedColumn<double> rpmBigStep = GeneratedColumn<double>(
    'rpm_big_step',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String>
  extras = GeneratedColumn<String>(
    'extras',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  ).withConverter<Map<String, dynamic>?>($GrindersTable.$converterextras);
  @override
  List<GeneratedColumn> get $columns => [
    id,
    model,
    burrs,
    burrSize,
    burrType,
    notes,
    archived,
    settingType,
    settingValues,
    settingSmallStep,
    settingBigStep,
    rpmSmallStep,
    rpmBigStep,
    createdAt,
    updatedAt,
    extras,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'grinders';
  @override
  VerificationContext validateIntegrity(
    Insertable<Grinder> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    } else if (isInserting) {
      context.missing(_modelMeta);
    }
    if (data.containsKey('burrs')) {
      context.handle(
        _burrsMeta,
        burrs.isAcceptableOrUnknown(data['burrs']!, _burrsMeta),
      );
    }
    if (data.containsKey('burr_size')) {
      context.handle(
        _burrSizeMeta,
        burrSize.isAcceptableOrUnknown(data['burr_size']!, _burrSizeMeta),
      );
    }
    if (data.containsKey('burr_type')) {
      context.handle(
        _burrTypeMeta,
        burrType.isAcceptableOrUnknown(data['burr_type']!, _burrTypeMeta),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('archived')) {
      context.handle(
        _archivedMeta,
        archived.isAcceptableOrUnknown(data['archived']!, _archivedMeta),
      );
    }
    if (data.containsKey('setting_type')) {
      context.handle(
        _settingTypeMeta,
        settingType.isAcceptableOrUnknown(
          data['setting_type']!,
          _settingTypeMeta,
        ),
      );
    }
    if (data.containsKey('setting_small_step')) {
      context.handle(
        _settingSmallStepMeta,
        settingSmallStep.isAcceptableOrUnknown(
          data['setting_small_step']!,
          _settingSmallStepMeta,
        ),
      );
    }
    if (data.containsKey('setting_big_step')) {
      context.handle(
        _settingBigStepMeta,
        settingBigStep.isAcceptableOrUnknown(
          data['setting_big_step']!,
          _settingBigStepMeta,
        ),
      );
    }
    if (data.containsKey('rpm_small_step')) {
      context.handle(
        _rpmSmallStepMeta,
        rpmSmallStep.isAcceptableOrUnknown(
          data['rpm_small_step']!,
          _rpmSmallStepMeta,
        ),
      );
    }
    if (data.containsKey('rpm_big_step')) {
      context.handle(
        _rpmBigStepMeta,
        rpmBigStep.isAcceptableOrUnknown(
          data['rpm_big_step']!,
          _rpmBigStepMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Grinder map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Grinder(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      )!,
      burrs: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}burrs'],
      ),
      burrSize: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}burr_size'],
      ),
      burrType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}burr_type'],
      ),
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      archived: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}archived'],
      )!,
      settingType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}setting_type'],
      )!,
      settingValues: $GrindersTable.$convertersettingValues.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}setting_values'],
        ),
      ),
      settingSmallStep: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}setting_small_step'],
      ),
      settingBigStep: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}setting_big_step'],
      ),
      rpmSmallStep: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}rpm_small_step'],
      ),
      rpmBigStep: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}rpm_big_step'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      extras: $GrindersTable.$converterextras.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}extras'],
        ),
      ),
    );
  }

  @override
  $GrindersTable createAlias(String alias) {
    return $GrindersTable(attachedDatabase, alias);
  }

  static TypeConverter<List<String>?, String?> $convertersettingValues =
      const NullableStringListConverter();
  static TypeConverter<Map<String, dynamic>?, String?> $converterextras =
      const NullableJsonMapConverter();
}

class Grinder extends DataClass implements Insertable<Grinder> {
  final String id;
  final String model;
  final String? burrs;
  final double? burrSize;
  final String? burrType;
  final String? notes;
  final bool archived;
  final String settingType;
  final List<String>? settingValues;
  final double? settingSmallStep;
  final double? settingBigStep;
  final double? rpmSmallStep;
  final double? rpmBigStep;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? extras;
  const Grinder({
    required this.id,
    required this.model,
    this.burrs,
    this.burrSize,
    this.burrType,
    this.notes,
    required this.archived,
    required this.settingType,
    this.settingValues,
    this.settingSmallStep,
    this.settingBigStep,
    this.rpmSmallStep,
    this.rpmBigStep,
    required this.createdAt,
    required this.updatedAt,
    this.extras,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['model'] = Variable<String>(model);
    if (!nullToAbsent || burrs != null) {
      map['burrs'] = Variable<String>(burrs);
    }
    if (!nullToAbsent || burrSize != null) {
      map['burr_size'] = Variable<double>(burrSize);
    }
    if (!nullToAbsent || burrType != null) {
      map['burr_type'] = Variable<String>(burrType);
    }
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    map['archived'] = Variable<bool>(archived);
    map['setting_type'] = Variable<String>(settingType);
    if (!nullToAbsent || settingValues != null) {
      map['setting_values'] = Variable<String>(
        $GrindersTable.$convertersettingValues.toSql(settingValues),
      );
    }
    if (!nullToAbsent || settingSmallStep != null) {
      map['setting_small_step'] = Variable<double>(settingSmallStep);
    }
    if (!nullToAbsent || settingBigStep != null) {
      map['setting_big_step'] = Variable<double>(settingBigStep);
    }
    if (!nullToAbsent || rpmSmallStep != null) {
      map['rpm_small_step'] = Variable<double>(rpmSmallStep);
    }
    if (!nullToAbsent || rpmBigStep != null) {
      map['rpm_big_step'] = Variable<double>(rpmBigStep);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || extras != null) {
      map['extras'] = Variable<String>(
        $GrindersTable.$converterextras.toSql(extras),
      );
    }
    return map;
  }

  GrindersCompanion toCompanion(bool nullToAbsent) {
    return GrindersCompanion(
      id: Value(id),
      model: Value(model),
      burrs: burrs == null && nullToAbsent
          ? const Value.absent()
          : Value(burrs),
      burrSize: burrSize == null && nullToAbsent
          ? const Value.absent()
          : Value(burrSize),
      burrType: burrType == null && nullToAbsent
          ? const Value.absent()
          : Value(burrType),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      archived: Value(archived),
      settingType: Value(settingType),
      settingValues: settingValues == null && nullToAbsent
          ? const Value.absent()
          : Value(settingValues),
      settingSmallStep: settingSmallStep == null && nullToAbsent
          ? const Value.absent()
          : Value(settingSmallStep),
      settingBigStep: settingBigStep == null && nullToAbsent
          ? const Value.absent()
          : Value(settingBigStep),
      rpmSmallStep: rpmSmallStep == null && nullToAbsent
          ? const Value.absent()
          : Value(rpmSmallStep),
      rpmBigStep: rpmBigStep == null && nullToAbsent
          ? const Value.absent()
          : Value(rpmBigStep),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      extras: extras == null && nullToAbsent
          ? const Value.absent()
          : Value(extras),
    );
  }

  factory Grinder.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Grinder(
      id: serializer.fromJson<String>(json['id']),
      model: serializer.fromJson<String>(json['model']),
      burrs: serializer.fromJson<String?>(json['burrs']),
      burrSize: serializer.fromJson<double?>(json['burrSize']),
      burrType: serializer.fromJson<String?>(json['burrType']),
      notes: serializer.fromJson<String?>(json['notes']),
      archived: serializer.fromJson<bool>(json['archived']),
      settingType: serializer.fromJson<String>(json['settingType']),
      settingValues: serializer.fromJson<List<String>?>(json['settingValues']),
      settingSmallStep: serializer.fromJson<double?>(json['settingSmallStep']),
      settingBigStep: serializer.fromJson<double?>(json['settingBigStep']),
      rpmSmallStep: serializer.fromJson<double?>(json['rpmSmallStep']),
      rpmBigStep: serializer.fromJson<double?>(json['rpmBigStep']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      extras: serializer.fromJson<Map<String, dynamic>?>(json['extras']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'model': serializer.toJson<String>(model),
      'burrs': serializer.toJson<String?>(burrs),
      'burrSize': serializer.toJson<double?>(burrSize),
      'burrType': serializer.toJson<String?>(burrType),
      'notes': serializer.toJson<String?>(notes),
      'archived': serializer.toJson<bool>(archived),
      'settingType': serializer.toJson<String>(settingType),
      'settingValues': serializer.toJson<List<String>?>(settingValues),
      'settingSmallStep': serializer.toJson<double?>(settingSmallStep),
      'settingBigStep': serializer.toJson<double?>(settingBigStep),
      'rpmSmallStep': serializer.toJson<double?>(rpmSmallStep),
      'rpmBigStep': serializer.toJson<double?>(rpmBigStep),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'extras': serializer.toJson<Map<String, dynamic>?>(extras),
    };
  }

  Grinder copyWith({
    String? id,
    String? model,
    Value<String?> burrs = const Value.absent(),
    Value<double?> burrSize = const Value.absent(),
    Value<String?> burrType = const Value.absent(),
    Value<String?> notes = const Value.absent(),
    bool? archived,
    String? settingType,
    Value<List<String>?> settingValues = const Value.absent(),
    Value<double?> settingSmallStep = const Value.absent(),
    Value<double?> settingBigStep = const Value.absent(),
    Value<double?> rpmSmallStep = const Value.absent(),
    Value<double?> rpmBigStep = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<Map<String, dynamic>?> extras = const Value.absent(),
  }) => Grinder(
    id: id ?? this.id,
    model: model ?? this.model,
    burrs: burrs.present ? burrs.value : this.burrs,
    burrSize: burrSize.present ? burrSize.value : this.burrSize,
    burrType: burrType.present ? burrType.value : this.burrType,
    notes: notes.present ? notes.value : this.notes,
    archived: archived ?? this.archived,
    settingType: settingType ?? this.settingType,
    settingValues: settingValues.present
        ? settingValues.value
        : this.settingValues,
    settingSmallStep: settingSmallStep.present
        ? settingSmallStep.value
        : this.settingSmallStep,
    settingBigStep: settingBigStep.present
        ? settingBigStep.value
        : this.settingBigStep,
    rpmSmallStep: rpmSmallStep.present ? rpmSmallStep.value : this.rpmSmallStep,
    rpmBigStep: rpmBigStep.present ? rpmBigStep.value : this.rpmBigStep,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    extras: extras.present ? extras.value : this.extras,
  );
  Grinder copyWithCompanion(GrindersCompanion data) {
    return Grinder(
      id: data.id.present ? data.id.value : this.id,
      model: data.model.present ? data.model.value : this.model,
      burrs: data.burrs.present ? data.burrs.value : this.burrs,
      burrSize: data.burrSize.present ? data.burrSize.value : this.burrSize,
      burrType: data.burrType.present ? data.burrType.value : this.burrType,
      notes: data.notes.present ? data.notes.value : this.notes,
      archived: data.archived.present ? data.archived.value : this.archived,
      settingType: data.settingType.present
          ? data.settingType.value
          : this.settingType,
      settingValues: data.settingValues.present
          ? data.settingValues.value
          : this.settingValues,
      settingSmallStep: data.settingSmallStep.present
          ? data.settingSmallStep.value
          : this.settingSmallStep,
      settingBigStep: data.settingBigStep.present
          ? data.settingBigStep.value
          : this.settingBigStep,
      rpmSmallStep: data.rpmSmallStep.present
          ? data.rpmSmallStep.value
          : this.rpmSmallStep,
      rpmBigStep: data.rpmBigStep.present
          ? data.rpmBigStep.value
          : this.rpmBigStep,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      extras: data.extras.present ? data.extras.value : this.extras,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Grinder(')
          ..write('id: $id, ')
          ..write('model: $model, ')
          ..write('burrs: $burrs, ')
          ..write('burrSize: $burrSize, ')
          ..write('burrType: $burrType, ')
          ..write('notes: $notes, ')
          ..write('archived: $archived, ')
          ..write('settingType: $settingType, ')
          ..write('settingValues: $settingValues, ')
          ..write('settingSmallStep: $settingSmallStep, ')
          ..write('settingBigStep: $settingBigStep, ')
          ..write('rpmSmallStep: $rpmSmallStep, ')
          ..write('rpmBigStep: $rpmBigStep, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('extras: $extras')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    model,
    burrs,
    burrSize,
    burrType,
    notes,
    archived,
    settingType,
    settingValues,
    settingSmallStep,
    settingBigStep,
    rpmSmallStep,
    rpmBigStep,
    createdAt,
    updatedAt,
    extras,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Grinder &&
          other.id == this.id &&
          other.model == this.model &&
          other.burrs == this.burrs &&
          other.burrSize == this.burrSize &&
          other.burrType == this.burrType &&
          other.notes == this.notes &&
          other.archived == this.archived &&
          other.settingType == this.settingType &&
          other.settingValues == this.settingValues &&
          other.settingSmallStep == this.settingSmallStep &&
          other.settingBigStep == this.settingBigStep &&
          other.rpmSmallStep == this.rpmSmallStep &&
          other.rpmBigStep == this.rpmBigStep &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.extras == this.extras);
}

class GrindersCompanion extends UpdateCompanion<Grinder> {
  final Value<String> id;
  final Value<String> model;
  final Value<String?> burrs;
  final Value<double?> burrSize;
  final Value<String?> burrType;
  final Value<String?> notes;
  final Value<bool> archived;
  final Value<String> settingType;
  final Value<List<String>?> settingValues;
  final Value<double?> settingSmallStep;
  final Value<double?> settingBigStep;
  final Value<double?> rpmSmallStep;
  final Value<double?> rpmBigStep;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<Map<String, dynamic>?> extras;
  final Value<int> rowid;
  const GrindersCompanion({
    this.id = const Value.absent(),
    this.model = const Value.absent(),
    this.burrs = const Value.absent(),
    this.burrSize = const Value.absent(),
    this.burrType = const Value.absent(),
    this.notes = const Value.absent(),
    this.archived = const Value.absent(),
    this.settingType = const Value.absent(),
    this.settingValues = const Value.absent(),
    this.settingSmallStep = const Value.absent(),
    this.settingBigStep = const Value.absent(),
    this.rpmSmallStep = const Value.absent(),
    this.rpmBigStep = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.extras = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GrindersCompanion.insert({
    required String id,
    required String model,
    this.burrs = const Value.absent(),
    this.burrSize = const Value.absent(),
    this.burrType = const Value.absent(),
    this.notes = const Value.absent(),
    this.archived = const Value.absent(),
    this.settingType = const Value.absent(),
    this.settingValues = const Value.absent(),
    this.settingSmallStep = const Value.absent(),
    this.settingBigStep = const Value.absent(),
    this.rpmSmallStep = const Value.absent(),
    this.rpmBigStep = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.extras = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       model = Value(model),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Grinder> custom({
    Expression<String>? id,
    Expression<String>? model,
    Expression<String>? burrs,
    Expression<double>? burrSize,
    Expression<String>? burrType,
    Expression<String>? notes,
    Expression<bool>? archived,
    Expression<String>? settingType,
    Expression<String>? settingValues,
    Expression<double>? settingSmallStep,
    Expression<double>? settingBigStep,
    Expression<double>? rpmSmallStep,
    Expression<double>? rpmBigStep,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? extras,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (model != null) 'model': model,
      if (burrs != null) 'burrs': burrs,
      if (burrSize != null) 'burr_size': burrSize,
      if (burrType != null) 'burr_type': burrType,
      if (notes != null) 'notes': notes,
      if (archived != null) 'archived': archived,
      if (settingType != null) 'setting_type': settingType,
      if (settingValues != null) 'setting_values': settingValues,
      if (settingSmallStep != null) 'setting_small_step': settingSmallStep,
      if (settingBigStep != null) 'setting_big_step': settingBigStep,
      if (rpmSmallStep != null) 'rpm_small_step': rpmSmallStep,
      if (rpmBigStep != null) 'rpm_big_step': rpmBigStep,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (extras != null) 'extras': extras,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GrindersCompanion copyWith({
    Value<String>? id,
    Value<String>? model,
    Value<String?>? burrs,
    Value<double?>? burrSize,
    Value<String?>? burrType,
    Value<String?>? notes,
    Value<bool>? archived,
    Value<String>? settingType,
    Value<List<String>?>? settingValues,
    Value<double?>? settingSmallStep,
    Value<double?>? settingBigStep,
    Value<double?>? rpmSmallStep,
    Value<double?>? rpmBigStep,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<Map<String, dynamic>?>? extras,
    Value<int>? rowid,
  }) {
    return GrindersCompanion(
      id: id ?? this.id,
      model: model ?? this.model,
      burrs: burrs ?? this.burrs,
      burrSize: burrSize ?? this.burrSize,
      burrType: burrType ?? this.burrType,
      notes: notes ?? this.notes,
      archived: archived ?? this.archived,
      settingType: settingType ?? this.settingType,
      settingValues: settingValues ?? this.settingValues,
      settingSmallStep: settingSmallStep ?? this.settingSmallStep,
      settingBigStep: settingBigStep ?? this.settingBigStep,
      rpmSmallStep: rpmSmallStep ?? this.rpmSmallStep,
      rpmBigStep: rpmBigStep ?? this.rpmBigStep,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      extras: extras ?? this.extras,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (burrs.present) {
      map['burrs'] = Variable<String>(burrs.value);
    }
    if (burrSize.present) {
      map['burr_size'] = Variable<double>(burrSize.value);
    }
    if (burrType.present) {
      map['burr_type'] = Variable<String>(burrType.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (archived.present) {
      map['archived'] = Variable<bool>(archived.value);
    }
    if (settingType.present) {
      map['setting_type'] = Variable<String>(settingType.value);
    }
    if (settingValues.present) {
      map['setting_values'] = Variable<String>(
        $GrindersTable.$convertersettingValues.toSql(settingValues.value),
      );
    }
    if (settingSmallStep.present) {
      map['setting_small_step'] = Variable<double>(settingSmallStep.value);
    }
    if (settingBigStep.present) {
      map['setting_big_step'] = Variable<double>(settingBigStep.value);
    }
    if (rpmSmallStep.present) {
      map['rpm_small_step'] = Variable<double>(rpmSmallStep.value);
    }
    if (rpmBigStep.present) {
      map['rpm_big_step'] = Variable<double>(rpmBigStep.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (extras.present) {
      map['extras'] = Variable<String>(
        $GrindersTable.$converterextras.toSql(extras.value),
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GrindersCompanion(')
          ..write('id: $id, ')
          ..write('model: $model, ')
          ..write('burrs: $burrs, ')
          ..write('burrSize: $burrSize, ')
          ..write('burrType: $burrType, ')
          ..write('notes: $notes, ')
          ..write('archived: $archived, ')
          ..write('settingType: $settingType, ')
          ..write('settingValues: $settingValues, ')
          ..write('settingSmallStep: $settingSmallStep, ')
          ..write('settingBigStep: $settingBigStep, ')
          ..write('rpmSmallStep: $rpmSmallStep, ')
          ..write('rpmBigStep: $rpmBigStep, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('extras: $extras, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ShotRecordsTable extends ShotRecords
    with TableInfo<$ShotRecordsTable, ShotRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ShotRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<DateTime> timestamp = GeneratedColumn<DateTime>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _profileTitleMeta = const VerificationMeta(
    'profileTitle',
  );
  @override
  late final GeneratedColumn<String> profileTitle = GeneratedColumn<String>(
    'profile_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _grinderIdMeta = const VerificationMeta(
    'grinderId',
  );
  @override
  late final GeneratedColumn<String> grinderId = GeneratedColumn<String>(
    'grinder_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _grinderModelMeta = const VerificationMeta(
    'grinderModel',
  );
  @override
  late final GeneratedColumn<String> grinderModel = GeneratedColumn<String>(
    'grinder_model',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _grinderSettingMeta = const VerificationMeta(
    'grinderSetting',
  );
  @override
  late final GeneratedColumn<String> grinderSetting = GeneratedColumn<String>(
    'grinder_setting',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _beanBatchIdMeta = const VerificationMeta(
    'beanBatchId',
  );
  @override
  late final GeneratedColumn<String> beanBatchId = GeneratedColumn<String>(
    'bean_batch_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _coffeeNameMeta = const VerificationMeta(
    'coffeeName',
  );
  @override
  late final GeneratedColumn<String> coffeeName = GeneratedColumn<String>(
    'coffee_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _coffeeRoasterMeta = const VerificationMeta(
    'coffeeRoaster',
  );
  @override
  late final GeneratedColumn<String> coffeeRoaster = GeneratedColumn<String>(
    'coffee_roaster',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _targetDoseWeightMeta = const VerificationMeta(
    'targetDoseWeight',
  );
  @override
  late final GeneratedColumn<double> targetDoseWeight = GeneratedColumn<double>(
    'target_dose_weight',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _targetYieldMeta = const VerificationMeta(
    'targetYield',
  );
  @override
  late final GeneratedColumn<double> targetYield = GeneratedColumn<double>(
    'target_yield',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _enjoymentMeta = const VerificationMeta(
    'enjoyment',
  );
  @override
  late final GeneratedColumn<double> enjoyment = GeneratedColumn<double>(
    'enjoyment',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _espressoNotesMeta = const VerificationMeta(
    'espressoNotes',
  );
  @override
  late final GeneratedColumn<String> espressoNotes = GeneratedColumn<String>(
    'espresso_notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stopReasonMeta = const VerificationMeta(
    'stopReason',
  );
  @override
  late final GeneratedColumn<String> stopReason = GeneratedColumn<String>(
    'stop_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>, String>
  workflowJson =
      GeneratedColumn<String>(
        'workflow_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<Map<String, dynamic>>(
        $ShotRecordsTable.$converterworkflowJson,
      );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String>
  annotationsJson =
      GeneratedColumn<String>(
        'annotations_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<Map<String, dynamic>?>(
        $ShotRecordsTable.$converterannotationsJson,
      );
  static const VerificationMeta _measurementsJsonMeta = const VerificationMeta(
    'measurementsJson',
  );
  @override
  late final GeneratedColumn<String> measurementsJson = GeneratedColumn<String>(
    'measurements_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    timestamp,
    profileTitle,
    grinderId,
    grinderModel,
    grinderSetting,
    beanBatchId,
    coffeeName,
    coffeeRoaster,
    targetDoseWeight,
    targetYield,
    enjoyment,
    espressoNotes,
    stopReason,
    createdAt,
    updatedAt,
    workflowJson,
    annotationsJson,
    measurementsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'shot_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<ShotRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('profile_title')) {
      context.handle(
        _profileTitleMeta,
        profileTitle.isAcceptableOrUnknown(
          data['profile_title']!,
          _profileTitleMeta,
        ),
      );
    }
    if (data.containsKey('grinder_id')) {
      context.handle(
        _grinderIdMeta,
        grinderId.isAcceptableOrUnknown(data['grinder_id']!, _grinderIdMeta),
      );
    }
    if (data.containsKey('grinder_model')) {
      context.handle(
        _grinderModelMeta,
        grinderModel.isAcceptableOrUnknown(
          data['grinder_model']!,
          _grinderModelMeta,
        ),
      );
    }
    if (data.containsKey('grinder_setting')) {
      context.handle(
        _grinderSettingMeta,
        grinderSetting.isAcceptableOrUnknown(
          data['grinder_setting']!,
          _grinderSettingMeta,
        ),
      );
    }
    if (data.containsKey('bean_batch_id')) {
      context.handle(
        _beanBatchIdMeta,
        beanBatchId.isAcceptableOrUnknown(
          data['bean_batch_id']!,
          _beanBatchIdMeta,
        ),
      );
    }
    if (data.containsKey('coffee_name')) {
      context.handle(
        _coffeeNameMeta,
        coffeeName.isAcceptableOrUnknown(data['coffee_name']!, _coffeeNameMeta),
      );
    }
    if (data.containsKey('coffee_roaster')) {
      context.handle(
        _coffeeRoasterMeta,
        coffeeRoaster.isAcceptableOrUnknown(
          data['coffee_roaster']!,
          _coffeeRoasterMeta,
        ),
      );
    }
    if (data.containsKey('target_dose_weight')) {
      context.handle(
        _targetDoseWeightMeta,
        targetDoseWeight.isAcceptableOrUnknown(
          data['target_dose_weight']!,
          _targetDoseWeightMeta,
        ),
      );
    }
    if (data.containsKey('target_yield')) {
      context.handle(
        _targetYieldMeta,
        targetYield.isAcceptableOrUnknown(
          data['target_yield']!,
          _targetYieldMeta,
        ),
      );
    }
    if (data.containsKey('enjoyment')) {
      context.handle(
        _enjoymentMeta,
        enjoyment.isAcceptableOrUnknown(data['enjoyment']!, _enjoymentMeta),
      );
    }
    if (data.containsKey('espresso_notes')) {
      context.handle(
        _espressoNotesMeta,
        espressoNotes.isAcceptableOrUnknown(
          data['espresso_notes']!,
          _espressoNotesMeta,
        ),
      );
    }
    if (data.containsKey('stop_reason')) {
      context.handle(
        _stopReasonMeta,
        stopReason.isAcceptableOrUnknown(data['stop_reason']!, _stopReasonMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('measurements_json')) {
      context.handle(
        _measurementsJsonMeta,
        measurementsJson.isAcceptableOrUnknown(
          data['measurements_json']!,
          _measurementsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_measurementsJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ShotRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ShotRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}timestamp'],
      )!,
      profileTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_title'],
      ),
      grinderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}grinder_id'],
      ),
      grinderModel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}grinder_model'],
      ),
      grinderSetting: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}grinder_setting'],
      ),
      beanBatchId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bean_batch_id'],
      ),
      coffeeName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}coffee_name'],
      ),
      coffeeRoaster: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}coffee_roaster'],
      ),
      targetDoseWeight: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}target_dose_weight'],
      ),
      targetYield: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}target_yield'],
      ),
      enjoyment: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}enjoyment'],
      ),
      espressoNotes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}espresso_notes'],
      ),
      stopReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stop_reason'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      ),
      workflowJson: $ShotRecordsTable.$converterworkflowJson.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}workflow_json'],
        )!,
      ),
      annotationsJson: $ShotRecordsTable.$converterannotationsJson.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}annotations_json'],
        ),
      ),
      measurementsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}measurements_json'],
      )!,
    );
  }

  @override
  $ShotRecordsTable createAlias(String alias) {
    return $ShotRecordsTable(attachedDatabase, alias);
  }

  static TypeConverter<Map<String, dynamic>, String> $converterworkflowJson =
      const JsonMapConverter();
  static TypeConverter<Map<String, dynamic>?, String?>
  $converterannotationsJson = const NullableJsonMapConverter();
}

class ShotRecord extends DataClass implements Insertable<ShotRecord> {
  final String id;
  final DateTime timestamp;
  final String? profileTitle;
  final String? grinderId;
  final String? grinderModel;
  final String? grinderSetting;
  final String? beanBatchId;
  final String? coffeeName;
  final String? coffeeRoaster;
  final double? targetDoseWeight;
  final double? targetYield;
  final double? enjoyment;
  final String? espressoNotes;
  final String? stopReason;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final Map<String, dynamic> workflowJson;
  final Map<String, dynamic>? annotationsJson;
  final String measurementsJson;
  const ShotRecord({
    required this.id,
    required this.timestamp,
    this.profileTitle,
    this.grinderId,
    this.grinderModel,
    this.grinderSetting,
    this.beanBatchId,
    this.coffeeName,
    this.coffeeRoaster,
    this.targetDoseWeight,
    this.targetYield,
    this.enjoyment,
    this.espressoNotes,
    this.stopReason,
    this.createdAt,
    this.updatedAt,
    required this.workflowJson,
    this.annotationsJson,
    required this.measurementsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['timestamp'] = Variable<DateTime>(timestamp);
    if (!nullToAbsent || profileTitle != null) {
      map['profile_title'] = Variable<String>(profileTitle);
    }
    if (!nullToAbsent || grinderId != null) {
      map['grinder_id'] = Variable<String>(grinderId);
    }
    if (!nullToAbsent || grinderModel != null) {
      map['grinder_model'] = Variable<String>(grinderModel);
    }
    if (!nullToAbsent || grinderSetting != null) {
      map['grinder_setting'] = Variable<String>(grinderSetting);
    }
    if (!nullToAbsent || beanBatchId != null) {
      map['bean_batch_id'] = Variable<String>(beanBatchId);
    }
    if (!nullToAbsent || coffeeName != null) {
      map['coffee_name'] = Variable<String>(coffeeName);
    }
    if (!nullToAbsent || coffeeRoaster != null) {
      map['coffee_roaster'] = Variable<String>(coffeeRoaster);
    }
    if (!nullToAbsent || targetDoseWeight != null) {
      map['target_dose_weight'] = Variable<double>(targetDoseWeight);
    }
    if (!nullToAbsent || targetYield != null) {
      map['target_yield'] = Variable<double>(targetYield);
    }
    if (!nullToAbsent || enjoyment != null) {
      map['enjoyment'] = Variable<double>(enjoyment);
    }
    if (!nullToAbsent || espressoNotes != null) {
      map['espresso_notes'] = Variable<String>(espressoNotes);
    }
    if (!nullToAbsent || stopReason != null) {
      map['stop_reason'] = Variable<String>(stopReason);
    }
    if (!nullToAbsent || createdAt != null) {
      map['created_at'] = Variable<DateTime>(createdAt);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    {
      map['workflow_json'] = Variable<String>(
        $ShotRecordsTable.$converterworkflowJson.toSql(workflowJson),
      );
    }
    if (!nullToAbsent || annotationsJson != null) {
      map['annotations_json'] = Variable<String>(
        $ShotRecordsTable.$converterannotationsJson.toSql(annotationsJson),
      );
    }
    map['measurements_json'] = Variable<String>(measurementsJson);
    return map;
  }

  ShotRecordsCompanion toCompanion(bool nullToAbsent) {
    return ShotRecordsCompanion(
      id: Value(id),
      timestamp: Value(timestamp),
      profileTitle: profileTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(profileTitle),
      grinderId: grinderId == null && nullToAbsent
          ? const Value.absent()
          : Value(grinderId),
      grinderModel: grinderModel == null && nullToAbsent
          ? const Value.absent()
          : Value(grinderModel),
      grinderSetting: grinderSetting == null && nullToAbsent
          ? const Value.absent()
          : Value(grinderSetting),
      beanBatchId: beanBatchId == null && nullToAbsent
          ? const Value.absent()
          : Value(beanBatchId),
      coffeeName: coffeeName == null && nullToAbsent
          ? const Value.absent()
          : Value(coffeeName),
      coffeeRoaster: coffeeRoaster == null && nullToAbsent
          ? const Value.absent()
          : Value(coffeeRoaster),
      targetDoseWeight: targetDoseWeight == null && nullToAbsent
          ? const Value.absent()
          : Value(targetDoseWeight),
      targetYield: targetYield == null && nullToAbsent
          ? const Value.absent()
          : Value(targetYield),
      enjoyment: enjoyment == null && nullToAbsent
          ? const Value.absent()
          : Value(enjoyment),
      espressoNotes: espressoNotes == null && nullToAbsent
          ? const Value.absent()
          : Value(espressoNotes),
      stopReason: stopReason == null && nullToAbsent
          ? const Value.absent()
          : Value(stopReason),
      createdAt: createdAt == null && nullToAbsent
          ? const Value.absent()
          : Value(createdAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      workflowJson: Value(workflowJson),
      annotationsJson: annotationsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(annotationsJson),
      measurementsJson: Value(measurementsJson),
    );
  }

  factory ShotRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ShotRecord(
      id: serializer.fromJson<String>(json['id']),
      timestamp: serializer.fromJson<DateTime>(json['timestamp']),
      profileTitle: serializer.fromJson<String?>(json['profileTitle']),
      grinderId: serializer.fromJson<String?>(json['grinderId']),
      grinderModel: serializer.fromJson<String?>(json['grinderModel']),
      grinderSetting: serializer.fromJson<String?>(json['grinderSetting']),
      beanBatchId: serializer.fromJson<String?>(json['beanBatchId']),
      coffeeName: serializer.fromJson<String?>(json['coffeeName']),
      coffeeRoaster: serializer.fromJson<String?>(json['coffeeRoaster']),
      targetDoseWeight: serializer.fromJson<double?>(json['targetDoseWeight']),
      targetYield: serializer.fromJson<double?>(json['targetYield']),
      enjoyment: serializer.fromJson<double?>(json['enjoyment']),
      espressoNotes: serializer.fromJson<String?>(json['espressoNotes']),
      stopReason: serializer.fromJson<String?>(json['stopReason']),
      createdAt: serializer.fromJson<DateTime?>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      workflowJson: serializer.fromJson<Map<String, dynamic>>(
        json['workflowJson'],
      ),
      annotationsJson: serializer.fromJson<Map<String, dynamic>?>(
        json['annotationsJson'],
      ),
      measurementsJson: serializer.fromJson<String>(json['measurementsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'timestamp': serializer.toJson<DateTime>(timestamp),
      'profileTitle': serializer.toJson<String?>(profileTitle),
      'grinderId': serializer.toJson<String?>(grinderId),
      'grinderModel': serializer.toJson<String?>(grinderModel),
      'grinderSetting': serializer.toJson<String?>(grinderSetting),
      'beanBatchId': serializer.toJson<String?>(beanBatchId),
      'coffeeName': serializer.toJson<String?>(coffeeName),
      'coffeeRoaster': serializer.toJson<String?>(coffeeRoaster),
      'targetDoseWeight': serializer.toJson<double?>(targetDoseWeight),
      'targetYield': serializer.toJson<double?>(targetYield),
      'enjoyment': serializer.toJson<double?>(enjoyment),
      'espressoNotes': serializer.toJson<String?>(espressoNotes),
      'stopReason': serializer.toJson<String?>(stopReason),
      'createdAt': serializer.toJson<DateTime?>(createdAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'workflowJson': serializer.toJson<Map<String, dynamic>>(workflowJson),
      'annotationsJson': serializer.toJson<Map<String, dynamic>?>(
        annotationsJson,
      ),
      'measurementsJson': serializer.toJson<String>(measurementsJson),
    };
  }

  ShotRecord copyWith({
    String? id,
    DateTime? timestamp,
    Value<String?> profileTitle = const Value.absent(),
    Value<String?> grinderId = const Value.absent(),
    Value<String?> grinderModel = const Value.absent(),
    Value<String?> grinderSetting = const Value.absent(),
    Value<String?> beanBatchId = const Value.absent(),
    Value<String?> coffeeName = const Value.absent(),
    Value<String?> coffeeRoaster = const Value.absent(),
    Value<double?> targetDoseWeight = const Value.absent(),
    Value<double?> targetYield = const Value.absent(),
    Value<double?> enjoyment = const Value.absent(),
    Value<String?> espressoNotes = const Value.absent(),
    Value<String?> stopReason = const Value.absent(),
    Value<DateTime?> createdAt = const Value.absent(),
    Value<DateTime?> updatedAt = const Value.absent(),
    Map<String, dynamic>? workflowJson,
    Value<Map<String, dynamic>?> annotationsJson = const Value.absent(),
    String? measurementsJson,
  }) => ShotRecord(
    id: id ?? this.id,
    timestamp: timestamp ?? this.timestamp,
    profileTitle: profileTitle.present ? profileTitle.value : this.profileTitle,
    grinderId: grinderId.present ? grinderId.value : this.grinderId,
    grinderModel: grinderModel.present ? grinderModel.value : this.grinderModel,
    grinderSetting: grinderSetting.present
        ? grinderSetting.value
        : this.grinderSetting,
    beanBatchId: beanBatchId.present ? beanBatchId.value : this.beanBatchId,
    coffeeName: coffeeName.present ? coffeeName.value : this.coffeeName,
    coffeeRoaster: coffeeRoaster.present
        ? coffeeRoaster.value
        : this.coffeeRoaster,
    targetDoseWeight: targetDoseWeight.present
        ? targetDoseWeight.value
        : this.targetDoseWeight,
    targetYield: targetYield.present ? targetYield.value : this.targetYield,
    enjoyment: enjoyment.present ? enjoyment.value : this.enjoyment,
    espressoNotes: espressoNotes.present
        ? espressoNotes.value
        : this.espressoNotes,
    stopReason: stopReason.present ? stopReason.value : this.stopReason,
    createdAt: createdAt.present ? createdAt.value : this.createdAt,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
    workflowJson: workflowJson ?? this.workflowJson,
    annotationsJson: annotationsJson.present
        ? annotationsJson.value
        : this.annotationsJson,
    measurementsJson: measurementsJson ?? this.measurementsJson,
  );
  ShotRecord copyWithCompanion(ShotRecordsCompanion data) {
    return ShotRecord(
      id: data.id.present ? data.id.value : this.id,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      profileTitle: data.profileTitle.present
          ? data.profileTitle.value
          : this.profileTitle,
      grinderId: data.grinderId.present ? data.grinderId.value : this.grinderId,
      grinderModel: data.grinderModel.present
          ? data.grinderModel.value
          : this.grinderModel,
      grinderSetting: data.grinderSetting.present
          ? data.grinderSetting.value
          : this.grinderSetting,
      beanBatchId: data.beanBatchId.present
          ? data.beanBatchId.value
          : this.beanBatchId,
      coffeeName: data.coffeeName.present
          ? data.coffeeName.value
          : this.coffeeName,
      coffeeRoaster: data.coffeeRoaster.present
          ? data.coffeeRoaster.value
          : this.coffeeRoaster,
      targetDoseWeight: data.targetDoseWeight.present
          ? data.targetDoseWeight.value
          : this.targetDoseWeight,
      targetYield: data.targetYield.present
          ? data.targetYield.value
          : this.targetYield,
      enjoyment: data.enjoyment.present ? data.enjoyment.value : this.enjoyment,
      espressoNotes: data.espressoNotes.present
          ? data.espressoNotes.value
          : this.espressoNotes,
      stopReason: data.stopReason.present
          ? data.stopReason.value
          : this.stopReason,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      workflowJson: data.workflowJson.present
          ? data.workflowJson.value
          : this.workflowJson,
      annotationsJson: data.annotationsJson.present
          ? data.annotationsJson.value
          : this.annotationsJson,
      measurementsJson: data.measurementsJson.present
          ? data.measurementsJson.value
          : this.measurementsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ShotRecord(')
          ..write('id: $id, ')
          ..write('timestamp: $timestamp, ')
          ..write('profileTitle: $profileTitle, ')
          ..write('grinderId: $grinderId, ')
          ..write('grinderModel: $grinderModel, ')
          ..write('grinderSetting: $grinderSetting, ')
          ..write('beanBatchId: $beanBatchId, ')
          ..write('coffeeName: $coffeeName, ')
          ..write('coffeeRoaster: $coffeeRoaster, ')
          ..write('targetDoseWeight: $targetDoseWeight, ')
          ..write('targetYield: $targetYield, ')
          ..write('enjoyment: $enjoyment, ')
          ..write('espressoNotes: $espressoNotes, ')
          ..write('stopReason: $stopReason, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('workflowJson: $workflowJson, ')
          ..write('annotationsJson: $annotationsJson, ')
          ..write('measurementsJson: $measurementsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    timestamp,
    profileTitle,
    grinderId,
    grinderModel,
    grinderSetting,
    beanBatchId,
    coffeeName,
    coffeeRoaster,
    targetDoseWeight,
    targetYield,
    enjoyment,
    espressoNotes,
    stopReason,
    createdAt,
    updatedAt,
    workflowJson,
    annotationsJson,
    measurementsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ShotRecord &&
          other.id == this.id &&
          other.timestamp == this.timestamp &&
          other.profileTitle == this.profileTitle &&
          other.grinderId == this.grinderId &&
          other.grinderModel == this.grinderModel &&
          other.grinderSetting == this.grinderSetting &&
          other.beanBatchId == this.beanBatchId &&
          other.coffeeName == this.coffeeName &&
          other.coffeeRoaster == this.coffeeRoaster &&
          other.targetDoseWeight == this.targetDoseWeight &&
          other.targetYield == this.targetYield &&
          other.enjoyment == this.enjoyment &&
          other.espressoNotes == this.espressoNotes &&
          other.stopReason == this.stopReason &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.workflowJson == this.workflowJson &&
          other.annotationsJson == this.annotationsJson &&
          other.measurementsJson == this.measurementsJson);
}

class ShotRecordsCompanion extends UpdateCompanion<ShotRecord> {
  final Value<String> id;
  final Value<DateTime> timestamp;
  final Value<String?> profileTitle;
  final Value<String?> grinderId;
  final Value<String?> grinderModel;
  final Value<String?> grinderSetting;
  final Value<String?> beanBatchId;
  final Value<String?> coffeeName;
  final Value<String?> coffeeRoaster;
  final Value<double?> targetDoseWeight;
  final Value<double?> targetYield;
  final Value<double?> enjoyment;
  final Value<String?> espressoNotes;
  final Value<String?> stopReason;
  final Value<DateTime?> createdAt;
  final Value<DateTime?> updatedAt;
  final Value<Map<String, dynamic>> workflowJson;
  final Value<Map<String, dynamic>?> annotationsJson;
  final Value<String> measurementsJson;
  final Value<int> rowid;
  const ShotRecordsCompanion({
    this.id = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.profileTitle = const Value.absent(),
    this.grinderId = const Value.absent(),
    this.grinderModel = const Value.absent(),
    this.grinderSetting = const Value.absent(),
    this.beanBatchId = const Value.absent(),
    this.coffeeName = const Value.absent(),
    this.coffeeRoaster = const Value.absent(),
    this.targetDoseWeight = const Value.absent(),
    this.targetYield = const Value.absent(),
    this.enjoyment = const Value.absent(),
    this.espressoNotes = const Value.absent(),
    this.stopReason = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.workflowJson = const Value.absent(),
    this.annotationsJson = const Value.absent(),
    this.measurementsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ShotRecordsCompanion.insert({
    required String id,
    required DateTime timestamp,
    this.profileTitle = const Value.absent(),
    this.grinderId = const Value.absent(),
    this.grinderModel = const Value.absent(),
    this.grinderSetting = const Value.absent(),
    this.beanBatchId = const Value.absent(),
    this.coffeeName = const Value.absent(),
    this.coffeeRoaster = const Value.absent(),
    this.targetDoseWeight = const Value.absent(),
    this.targetYield = const Value.absent(),
    this.enjoyment = const Value.absent(),
    this.espressoNotes = const Value.absent(),
    this.stopReason = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    required Map<String, dynamic> workflowJson,
    this.annotationsJson = const Value.absent(),
    required String measurementsJson,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       timestamp = Value(timestamp),
       workflowJson = Value(workflowJson),
       measurementsJson = Value(measurementsJson);
  static Insertable<ShotRecord> custom({
    Expression<String>? id,
    Expression<DateTime>? timestamp,
    Expression<String>? profileTitle,
    Expression<String>? grinderId,
    Expression<String>? grinderModel,
    Expression<String>? grinderSetting,
    Expression<String>? beanBatchId,
    Expression<String>? coffeeName,
    Expression<String>? coffeeRoaster,
    Expression<double>? targetDoseWeight,
    Expression<double>? targetYield,
    Expression<double>? enjoyment,
    Expression<String>? espressoNotes,
    Expression<String>? stopReason,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? workflowJson,
    Expression<String>? annotationsJson,
    Expression<String>? measurementsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (timestamp != null) 'timestamp': timestamp,
      if (profileTitle != null) 'profile_title': profileTitle,
      if (grinderId != null) 'grinder_id': grinderId,
      if (grinderModel != null) 'grinder_model': grinderModel,
      if (grinderSetting != null) 'grinder_setting': grinderSetting,
      if (beanBatchId != null) 'bean_batch_id': beanBatchId,
      if (coffeeName != null) 'coffee_name': coffeeName,
      if (coffeeRoaster != null) 'coffee_roaster': coffeeRoaster,
      if (targetDoseWeight != null) 'target_dose_weight': targetDoseWeight,
      if (targetYield != null) 'target_yield': targetYield,
      if (enjoyment != null) 'enjoyment': enjoyment,
      if (espressoNotes != null) 'espresso_notes': espressoNotes,
      if (stopReason != null) 'stop_reason': stopReason,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (workflowJson != null) 'workflow_json': workflowJson,
      if (annotationsJson != null) 'annotations_json': annotationsJson,
      if (measurementsJson != null) 'measurements_json': measurementsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ShotRecordsCompanion copyWith({
    Value<String>? id,
    Value<DateTime>? timestamp,
    Value<String?>? profileTitle,
    Value<String?>? grinderId,
    Value<String?>? grinderModel,
    Value<String?>? grinderSetting,
    Value<String?>? beanBatchId,
    Value<String?>? coffeeName,
    Value<String?>? coffeeRoaster,
    Value<double?>? targetDoseWeight,
    Value<double?>? targetYield,
    Value<double?>? enjoyment,
    Value<String?>? espressoNotes,
    Value<String?>? stopReason,
    Value<DateTime?>? createdAt,
    Value<DateTime?>? updatedAt,
    Value<Map<String, dynamic>>? workflowJson,
    Value<Map<String, dynamic>?>? annotationsJson,
    Value<String>? measurementsJson,
    Value<int>? rowid,
  }) {
    return ShotRecordsCompanion(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      profileTitle: profileTitle ?? this.profileTitle,
      grinderId: grinderId ?? this.grinderId,
      grinderModel: grinderModel ?? this.grinderModel,
      grinderSetting: grinderSetting ?? this.grinderSetting,
      beanBatchId: beanBatchId ?? this.beanBatchId,
      coffeeName: coffeeName ?? this.coffeeName,
      coffeeRoaster: coffeeRoaster ?? this.coffeeRoaster,
      targetDoseWeight: targetDoseWeight ?? this.targetDoseWeight,
      targetYield: targetYield ?? this.targetYield,
      enjoyment: enjoyment ?? this.enjoyment,
      espressoNotes: espressoNotes ?? this.espressoNotes,
      stopReason: stopReason ?? this.stopReason,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      workflowJson: workflowJson ?? this.workflowJson,
      annotationsJson: annotationsJson ?? this.annotationsJson,
      measurementsJson: measurementsJson ?? this.measurementsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<DateTime>(timestamp.value);
    }
    if (profileTitle.present) {
      map['profile_title'] = Variable<String>(profileTitle.value);
    }
    if (grinderId.present) {
      map['grinder_id'] = Variable<String>(grinderId.value);
    }
    if (grinderModel.present) {
      map['grinder_model'] = Variable<String>(grinderModel.value);
    }
    if (grinderSetting.present) {
      map['grinder_setting'] = Variable<String>(grinderSetting.value);
    }
    if (beanBatchId.present) {
      map['bean_batch_id'] = Variable<String>(beanBatchId.value);
    }
    if (coffeeName.present) {
      map['coffee_name'] = Variable<String>(coffeeName.value);
    }
    if (coffeeRoaster.present) {
      map['coffee_roaster'] = Variable<String>(coffeeRoaster.value);
    }
    if (targetDoseWeight.present) {
      map['target_dose_weight'] = Variable<double>(targetDoseWeight.value);
    }
    if (targetYield.present) {
      map['target_yield'] = Variable<double>(targetYield.value);
    }
    if (enjoyment.present) {
      map['enjoyment'] = Variable<double>(enjoyment.value);
    }
    if (espressoNotes.present) {
      map['espresso_notes'] = Variable<String>(espressoNotes.value);
    }
    if (stopReason.present) {
      map['stop_reason'] = Variable<String>(stopReason.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (workflowJson.present) {
      map['workflow_json'] = Variable<String>(
        $ShotRecordsTable.$converterworkflowJson.toSql(workflowJson.value),
      );
    }
    if (annotationsJson.present) {
      map['annotations_json'] = Variable<String>(
        $ShotRecordsTable.$converterannotationsJson.toSql(
          annotationsJson.value,
        ),
      );
    }
    if (measurementsJson.present) {
      map['measurements_json'] = Variable<String>(measurementsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ShotRecordsCompanion(')
          ..write('id: $id, ')
          ..write('timestamp: $timestamp, ')
          ..write('profileTitle: $profileTitle, ')
          ..write('grinderId: $grinderId, ')
          ..write('grinderModel: $grinderModel, ')
          ..write('grinderSetting: $grinderSetting, ')
          ..write('beanBatchId: $beanBatchId, ')
          ..write('coffeeName: $coffeeName, ')
          ..write('coffeeRoaster: $coffeeRoaster, ')
          ..write('targetDoseWeight: $targetDoseWeight, ')
          ..write('targetYield: $targetYield, ')
          ..write('enjoyment: $enjoyment, ')
          ..write('espressoNotes: $espressoNotes, ')
          ..write('stopReason: $stopReason, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('workflowJson: $workflowJson, ')
          ..write('annotationsJson: $annotationsJson, ')
          ..write('measurementsJson: $measurementsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SteamRecordsTable extends SteamRecords
    with TableInfo<$SteamRecordsTable, SteamRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SteamRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<DateTime> timestamp = GeneratedColumn<DateTime>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>, String>
  workflowJson =
      GeneratedColumn<String>(
        'workflow_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<Map<String, dynamic>>(
        $SteamRecordsTable.$converterworkflowJson,
      );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String>
  annotationsJson =
      GeneratedColumn<String>(
        'annotations_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<Map<String, dynamic>?>(
        $SteamRecordsTable.$converterannotationsJson,
      );
  static const VerificationMeta _measurementsJsonMeta = const VerificationMeta(
    'measurementsJson',
  );
  @override
  late final GeneratedColumn<String> measurementsJson = GeneratedColumn<String>(
    'measurements_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    timestamp,
    workflowJson,
    annotationsJson,
    measurementsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'steam_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<SteamRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('measurements_json')) {
      context.handle(
        _measurementsJsonMeta,
        measurementsJson.isAcceptableOrUnknown(
          data['measurements_json']!,
          _measurementsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_measurementsJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SteamRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SteamRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}timestamp'],
      )!,
      workflowJson: $SteamRecordsTable.$converterworkflowJson.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}workflow_json'],
        )!,
      ),
      annotationsJson: $SteamRecordsTable.$converterannotationsJson.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}annotations_json'],
        ),
      ),
      measurementsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}measurements_json'],
      )!,
    );
  }

  @override
  $SteamRecordsTable createAlias(String alias) {
    return $SteamRecordsTable(attachedDatabase, alias);
  }

  static TypeConverter<Map<String, dynamic>, String> $converterworkflowJson =
      const JsonMapConverter();
  static TypeConverter<Map<String, dynamic>?, String?>
  $converterannotationsJson = const NullableJsonMapConverter();
}

class SteamRecord extends DataClass implements Insertable<SteamRecord> {
  final String id;
  final DateTime timestamp;
  final Map<String, dynamic> workflowJson;
  final Map<String, dynamic>? annotationsJson;
  final String measurementsJson;
  const SteamRecord({
    required this.id,
    required this.timestamp,
    required this.workflowJson,
    this.annotationsJson,
    required this.measurementsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['timestamp'] = Variable<DateTime>(timestamp);
    {
      map['workflow_json'] = Variable<String>(
        $SteamRecordsTable.$converterworkflowJson.toSql(workflowJson),
      );
    }
    if (!nullToAbsent || annotationsJson != null) {
      map['annotations_json'] = Variable<String>(
        $SteamRecordsTable.$converterannotationsJson.toSql(annotationsJson),
      );
    }
    map['measurements_json'] = Variable<String>(measurementsJson);
    return map;
  }

  SteamRecordsCompanion toCompanion(bool nullToAbsent) {
    return SteamRecordsCompanion(
      id: Value(id),
      timestamp: Value(timestamp),
      workflowJson: Value(workflowJson),
      annotationsJson: annotationsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(annotationsJson),
      measurementsJson: Value(measurementsJson),
    );
  }

  factory SteamRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SteamRecord(
      id: serializer.fromJson<String>(json['id']),
      timestamp: serializer.fromJson<DateTime>(json['timestamp']),
      workflowJson: serializer.fromJson<Map<String, dynamic>>(
        json['workflowJson'],
      ),
      annotationsJson: serializer.fromJson<Map<String, dynamic>?>(
        json['annotationsJson'],
      ),
      measurementsJson: serializer.fromJson<String>(json['measurementsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'timestamp': serializer.toJson<DateTime>(timestamp),
      'workflowJson': serializer.toJson<Map<String, dynamic>>(workflowJson),
      'annotationsJson': serializer.toJson<Map<String, dynamic>?>(
        annotationsJson,
      ),
      'measurementsJson': serializer.toJson<String>(measurementsJson),
    };
  }

  SteamRecord copyWith({
    String? id,
    DateTime? timestamp,
    Map<String, dynamic>? workflowJson,
    Value<Map<String, dynamic>?> annotationsJson = const Value.absent(),
    String? measurementsJson,
  }) => SteamRecord(
    id: id ?? this.id,
    timestamp: timestamp ?? this.timestamp,
    workflowJson: workflowJson ?? this.workflowJson,
    annotationsJson: annotationsJson.present
        ? annotationsJson.value
        : this.annotationsJson,
    measurementsJson: measurementsJson ?? this.measurementsJson,
  );
  SteamRecord copyWithCompanion(SteamRecordsCompanion data) {
    return SteamRecord(
      id: data.id.present ? data.id.value : this.id,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      workflowJson: data.workflowJson.present
          ? data.workflowJson.value
          : this.workflowJson,
      annotationsJson: data.annotationsJson.present
          ? data.annotationsJson.value
          : this.annotationsJson,
      measurementsJson: data.measurementsJson.present
          ? data.measurementsJson.value
          : this.measurementsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SteamRecord(')
          ..write('id: $id, ')
          ..write('timestamp: $timestamp, ')
          ..write('workflowJson: $workflowJson, ')
          ..write('annotationsJson: $annotationsJson, ')
          ..write('measurementsJson: $measurementsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    timestamp,
    workflowJson,
    annotationsJson,
    measurementsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SteamRecord &&
          other.id == this.id &&
          other.timestamp == this.timestamp &&
          other.workflowJson == this.workflowJson &&
          other.annotationsJson == this.annotationsJson &&
          other.measurementsJson == this.measurementsJson);
}

class SteamRecordsCompanion extends UpdateCompanion<SteamRecord> {
  final Value<String> id;
  final Value<DateTime> timestamp;
  final Value<Map<String, dynamic>> workflowJson;
  final Value<Map<String, dynamic>?> annotationsJson;
  final Value<String> measurementsJson;
  final Value<int> rowid;
  const SteamRecordsCompanion({
    this.id = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.workflowJson = const Value.absent(),
    this.annotationsJson = const Value.absent(),
    this.measurementsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SteamRecordsCompanion.insert({
    required String id,
    required DateTime timestamp,
    required Map<String, dynamic> workflowJson,
    this.annotationsJson = const Value.absent(),
    required String measurementsJson,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       timestamp = Value(timestamp),
       workflowJson = Value(workflowJson),
       measurementsJson = Value(measurementsJson);
  static Insertable<SteamRecord> custom({
    Expression<String>? id,
    Expression<DateTime>? timestamp,
    Expression<String>? workflowJson,
    Expression<String>? annotationsJson,
    Expression<String>? measurementsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (timestamp != null) 'timestamp': timestamp,
      if (workflowJson != null) 'workflow_json': workflowJson,
      if (annotationsJson != null) 'annotations_json': annotationsJson,
      if (measurementsJson != null) 'measurements_json': measurementsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SteamRecordsCompanion copyWith({
    Value<String>? id,
    Value<DateTime>? timestamp,
    Value<Map<String, dynamic>>? workflowJson,
    Value<Map<String, dynamic>?>? annotationsJson,
    Value<String>? measurementsJson,
    Value<int>? rowid,
  }) {
    return SteamRecordsCompanion(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      workflowJson: workflowJson ?? this.workflowJson,
      annotationsJson: annotationsJson ?? this.annotationsJson,
      measurementsJson: measurementsJson ?? this.measurementsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<DateTime>(timestamp.value);
    }
    if (workflowJson.present) {
      map['workflow_json'] = Variable<String>(
        $SteamRecordsTable.$converterworkflowJson.toSql(workflowJson.value),
      );
    }
    if (annotationsJson.present) {
      map['annotations_json'] = Variable<String>(
        $SteamRecordsTable.$converterannotationsJson.toSql(
          annotationsJson.value,
        ),
      );
    }
    if (measurementsJson.present) {
      map['measurements_json'] = Variable<String>(measurementsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SteamRecordsCompanion(')
          ..write('id: $id, ')
          ..write('timestamp: $timestamp, ')
          ..write('workflowJson: $workflowJson, ')
          ..write('annotationsJson: $annotationsJson, ')
          ..write('measurementsJson: $measurementsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $WorkflowsTable extends Workflows
    with TableInfo<$WorkflowsTable, Workflow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WorkflowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>, String>
  workflowJson = GeneratedColumn<String>(
    'workflow_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  ).withConverter<Map<String, dynamic>>($WorkflowsTable.$converterworkflowJson);
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, workflowJson, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'workflows';
  @override
  VerificationContext validateIntegrity(
    Insertable<Workflow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Workflow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Workflow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      workflowJson: $WorkflowsTable.$converterworkflowJson.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}workflow_json'],
        )!,
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $WorkflowsTable createAlias(String alias) {
    return $WorkflowsTable(attachedDatabase, alias);
  }

  static TypeConverter<Map<String, dynamic>, String> $converterworkflowJson =
      const JsonMapConverter();
}

class Workflow extends DataClass implements Insertable<Workflow> {
  final String id;
  final Map<String, dynamic> workflowJson;
  final DateTime updatedAt;
  const Workflow({
    required this.id,
    required this.workflowJson,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    {
      map['workflow_json'] = Variable<String>(
        $WorkflowsTable.$converterworkflowJson.toSql(workflowJson),
      );
    }
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  WorkflowsCompanion toCompanion(bool nullToAbsent) {
    return WorkflowsCompanion(
      id: Value(id),
      workflowJson: Value(workflowJson),
      updatedAt: Value(updatedAt),
    );
  }

  factory Workflow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Workflow(
      id: serializer.fromJson<String>(json['id']),
      workflowJson: serializer.fromJson<Map<String, dynamic>>(
        json['workflowJson'],
      ),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'workflowJson': serializer.toJson<Map<String, dynamic>>(workflowJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  Workflow copyWith({
    String? id,
    Map<String, dynamic>? workflowJson,
    DateTime? updatedAt,
  }) => Workflow(
    id: id ?? this.id,
    workflowJson: workflowJson ?? this.workflowJson,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  Workflow copyWithCompanion(WorkflowsCompanion data) {
    return Workflow(
      id: data.id.present ? data.id.value : this.id,
      workflowJson: data.workflowJson.present
          ? data.workflowJson.value
          : this.workflowJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Workflow(')
          ..write('id: $id, ')
          ..write('workflowJson: $workflowJson, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, workflowJson, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Workflow &&
          other.id == this.id &&
          other.workflowJson == this.workflowJson &&
          other.updatedAt == this.updatedAt);
}

class WorkflowsCompanion extends UpdateCompanion<Workflow> {
  final Value<String> id;
  final Value<Map<String, dynamic>> workflowJson;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const WorkflowsCompanion({
    this.id = const Value.absent(),
    this.workflowJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WorkflowsCompanion.insert({
    required String id,
    required Map<String, dynamic> workflowJson,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       workflowJson = Value(workflowJson),
       updatedAt = Value(updatedAt);
  static Insertable<Workflow> custom({
    Expression<String>? id,
    Expression<String>? workflowJson,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (workflowJson != null) 'workflow_json': workflowJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WorkflowsCompanion copyWith({
    Value<String>? id,
    Value<Map<String, dynamic>>? workflowJson,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return WorkflowsCompanion(
      id: id ?? this.id,
      workflowJson: workflowJson ?? this.workflowJson,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (workflowJson.present) {
      map['workflow_json'] = Variable<String>(
        $WorkflowsTable.$converterworkflowJson.toSql(workflowJson.value),
      );
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WorkflowsCompanion(')
          ..write('id: $id, ')
          ..write('workflowJson: $workflowJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProfileRecordsTable extends ProfileRecords
    with TableInfo<$ProfileRecordsTable, ProfileRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfileRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _metadataHashMeta = const VerificationMeta(
    'metadataHash',
  );
  @override
  late final GeneratedColumn<String> metadataHash = GeneratedColumn<String>(
    'metadata_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _compoundHashMeta = const VerificationMeta(
    'compoundHash',
  );
  @override
  late final GeneratedColumn<String> compoundHash = GeneratedColumn<String>(
    'compound_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _visibilityMeta = const VerificationMeta(
    'visibility',
  );
  @override
  late final GeneratedColumn<String> visibility = GeneratedColumn<String>(
    'visibility',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('visible'),
  );
  static const VerificationMeta _isDefaultMeta = const VerificationMeta(
    'isDefault',
  );
  @override
  late final GeneratedColumn<bool> isDefault = GeneratedColumn<bool>(
    'is_default',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_default" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>, String>
  profileJson =
      GeneratedColumn<String>(
        'profile_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<Map<String, dynamic>>(
        $ProfileRecordsTable.$converterprofileJson,
      );
  @override
  late final GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String>
  metadata =
      GeneratedColumn<String>(
        'metadata',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<Map<String, dynamic>?>(
        $ProfileRecordsTable.$convertermetadata,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    metadataHash,
    compoundHash,
    parentId,
    visibility,
    isDefault,
    createdAt,
    updatedAt,
    profileJson,
    metadata,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profile_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProfileRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('metadata_hash')) {
      context.handle(
        _metadataHashMeta,
        metadataHash.isAcceptableOrUnknown(
          data['metadata_hash']!,
          _metadataHashMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_metadataHashMeta);
    }
    if (data.containsKey('compound_hash')) {
      context.handle(
        _compoundHashMeta,
        compoundHash.isAcceptableOrUnknown(
          data['compound_hash']!,
          _compoundHashMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_compoundHashMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('visibility')) {
      context.handle(
        _visibilityMeta,
        visibility.isAcceptableOrUnknown(data['visibility']!, _visibilityMeta),
      );
    }
    if (data.containsKey('is_default')) {
      context.handle(
        _isDefaultMeta,
        isDefault.isAcceptableOrUnknown(data['is_default']!, _isDefaultMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ProfileRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProfileRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      metadataHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metadata_hash'],
      )!,
      compoundHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}compound_hash'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      visibility: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}visibility'],
      )!,
      isDefault: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_default'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      profileJson: $ProfileRecordsTable.$converterprofileJson.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}profile_json'],
        )!,
      ),
      metadata: $ProfileRecordsTable.$convertermetadata.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}metadata'],
        ),
      ),
    );
  }

  @override
  $ProfileRecordsTable createAlias(String alias) {
    return $ProfileRecordsTable(attachedDatabase, alias);
  }

  static TypeConverter<Map<String, dynamic>, String> $converterprofileJson =
      const JsonMapConverter();
  static TypeConverter<Map<String, dynamic>?, String?> $convertermetadata =
      const NullableJsonMapConverter();
}

class ProfileRecord extends DataClass implements Insertable<ProfileRecord> {
  final String id;
  final String metadataHash;
  final String compoundHash;
  final String? parentId;
  final String visibility;
  final bool isDefault;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic> profileJson;
  final Map<String, dynamic>? metadata;
  const ProfileRecord({
    required this.id,
    required this.metadataHash,
    required this.compoundHash,
    this.parentId,
    required this.visibility,
    required this.isDefault,
    required this.createdAt,
    required this.updatedAt,
    required this.profileJson,
    this.metadata,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['metadata_hash'] = Variable<String>(metadataHash);
    map['compound_hash'] = Variable<String>(compoundHash);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['visibility'] = Variable<String>(visibility);
    map['is_default'] = Variable<bool>(isDefault);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    {
      map['profile_json'] = Variable<String>(
        $ProfileRecordsTable.$converterprofileJson.toSql(profileJson),
      );
    }
    if (!nullToAbsent || metadata != null) {
      map['metadata'] = Variable<String>(
        $ProfileRecordsTable.$convertermetadata.toSql(metadata),
      );
    }
    return map;
  }

  ProfileRecordsCompanion toCompanion(bool nullToAbsent) {
    return ProfileRecordsCompanion(
      id: Value(id),
      metadataHash: Value(metadataHash),
      compoundHash: Value(compoundHash),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      visibility: Value(visibility),
      isDefault: Value(isDefault),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      profileJson: Value(profileJson),
      metadata: metadata == null && nullToAbsent
          ? const Value.absent()
          : Value(metadata),
    );
  }

  factory ProfileRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProfileRecord(
      id: serializer.fromJson<String>(json['id']),
      metadataHash: serializer.fromJson<String>(json['metadataHash']),
      compoundHash: serializer.fromJson<String>(json['compoundHash']),
      parentId: serializer.fromJson<String?>(json['parentId']),
      visibility: serializer.fromJson<String>(json['visibility']),
      isDefault: serializer.fromJson<bool>(json['isDefault']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      profileJson: serializer.fromJson<Map<String, dynamic>>(
        json['profileJson'],
      ),
      metadata: serializer.fromJson<Map<String, dynamic>?>(json['metadata']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'metadataHash': serializer.toJson<String>(metadataHash),
      'compoundHash': serializer.toJson<String>(compoundHash),
      'parentId': serializer.toJson<String?>(parentId),
      'visibility': serializer.toJson<String>(visibility),
      'isDefault': serializer.toJson<bool>(isDefault),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'profileJson': serializer.toJson<Map<String, dynamic>>(profileJson),
      'metadata': serializer.toJson<Map<String, dynamic>?>(metadata),
    };
  }

  ProfileRecord copyWith({
    String? id,
    String? metadataHash,
    String? compoundHash,
    Value<String?> parentId = const Value.absent(),
    String? visibility,
    bool? isDefault,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? profileJson,
    Value<Map<String, dynamic>?> metadata = const Value.absent(),
  }) => ProfileRecord(
    id: id ?? this.id,
    metadataHash: metadataHash ?? this.metadataHash,
    compoundHash: compoundHash ?? this.compoundHash,
    parentId: parentId.present ? parentId.value : this.parentId,
    visibility: visibility ?? this.visibility,
    isDefault: isDefault ?? this.isDefault,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    profileJson: profileJson ?? this.profileJson,
    metadata: metadata.present ? metadata.value : this.metadata,
  );
  ProfileRecord copyWithCompanion(ProfileRecordsCompanion data) {
    return ProfileRecord(
      id: data.id.present ? data.id.value : this.id,
      metadataHash: data.metadataHash.present
          ? data.metadataHash.value
          : this.metadataHash,
      compoundHash: data.compoundHash.present
          ? data.compoundHash.value
          : this.compoundHash,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      visibility: data.visibility.present
          ? data.visibility.value
          : this.visibility,
      isDefault: data.isDefault.present ? data.isDefault.value : this.isDefault,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      profileJson: data.profileJson.present
          ? data.profileJson.value
          : this.profileJson,
      metadata: data.metadata.present ? data.metadata.value : this.metadata,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProfileRecord(')
          ..write('id: $id, ')
          ..write('metadataHash: $metadataHash, ')
          ..write('compoundHash: $compoundHash, ')
          ..write('parentId: $parentId, ')
          ..write('visibility: $visibility, ')
          ..write('isDefault: $isDefault, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('profileJson: $profileJson, ')
          ..write('metadata: $metadata')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    metadataHash,
    compoundHash,
    parentId,
    visibility,
    isDefault,
    createdAt,
    updatedAt,
    profileJson,
    metadata,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProfileRecord &&
          other.id == this.id &&
          other.metadataHash == this.metadataHash &&
          other.compoundHash == this.compoundHash &&
          other.parentId == this.parentId &&
          other.visibility == this.visibility &&
          other.isDefault == this.isDefault &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.profileJson == this.profileJson &&
          other.metadata == this.metadata);
}

class ProfileRecordsCompanion extends UpdateCompanion<ProfileRecord> {
  final Value<String> id;
  final Value<String> metadataHash;
  final Value<String> compoundHash;
  final Value<String?> parentId;
  final Value<String> visibility;
  final Value<bool> isDefault;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<Map<String, dynamic>> profileJson;
  final Value<Map<String, dynamic>?> metadata;
  final Value<int> rowid;
  const ProfileRecordsCompanion({
    this.id = const Value.absent(),
    this.metadataHash = const Value.absent(),
    this.compoundHash = const Value.absent(),
    this.parentId = const Value.absent(),
    this.visibility = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.profileJson = const Value.absent(),
    this.metadata = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProfileRecordsCompanion.insert({
    required String id,
    required String metadataHash,
    required String compoundHash,
    this.parentId = const Value.absent(),
    this.visibility = const Value.absent(),
    this.isDefault = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    required Map<String, dynamic> profileJson,
    this.metadata = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       metadataHash = Value(metadataHash),
       compoundHash = Value(compoundHash),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       profileJson = Value(profileJson);
  static Insertable<ProfileRecord> custom({
    Expression<String>? id,
    Expression<String>? metadataHash,
    Expression<String>? compoundHash,
    Expression<String>? parentId,
    Expression<String>? visibility,
    Expression<bool>? isDefault,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? profileJson,
    Expression<String>? metadata,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (metadataHash != null) 'metadata_hash': metadataHash,
      if (compoundHash != null) 'compound_hash': compoundHash,
      if (parentId != null) 'parent_id': parentId,
      if (visibility != null) 'visibility': visibility,
      if (isDefault != null) 'is_default': isDefault,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (profileJson != null) 'profile_json': profileJson,
      if (metadata != null) 'metadata': metadata,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProfileRecordsCompanion copyWith({
    Value<String>? id,
    Value<String>? metadataHash,
    Value<String>? compoundHash,
    Value<String?>? parentId,
    Value<String>? visibility,
    Value<bool>? isDefault,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<Map<String, dynamic>>? profileJson,
    Value<Map<String, dynamic>?>? metadata,
    Value<int>? rowid,
  }) {
    return ProfileRecordsCompanion(
      id: id ?? this.id,
      metadataHash: metadataHash ?? this.metadataHash,
      compoundHash: compoundHash ?? this.compoundHash,
      parentId: parentId ?? this.parentId,
      visibility: visibility ?? this.visibility,
      isDefault: isDefault ?? this.isDefault,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      profileJson: profileJson ?? this.profileJson,
      metadata: metadata ?? this.metadata,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (metadataHash.present) {
      map['metadata_hash'] = Variable<String>(metadataHash.value);
    }
    if (compoundHash.present) {
      map['compound_hash'] = Variable<String>(compoundHash.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (visibility.present) {
      map['visibility'] = Variable<String>(visibility.value);
    }
    if (isDefault.present) {
      map['is_default'] = Variable<bool>(isDefault.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (profileJson.present) {
      map['profile_json'] = Variable<String>(
        $ProfileRecordsTable.$converterprofileJson.toSql(profileJson.value),
      );
    }
    if (metadata.present) {
      map['metadata'] = Variable<String>(
        $ProfileRecordsTable.$convertermetadata.toSql(metadata.value),
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfileRecordsCompanion(')
          ..write('id: $id, ')
          ..write('metadataHash: $metadataHash, ')
          ..write('compoundHash: $compoundHash, ')
          ..write('parentId: $parentId, ')
          ..write('visibility: $visibility, ')
          ..write('isDefault: $isDefault, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('profileJson: $profileJson, ')
          ..write('metadata: $metadata, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $BeansTable beans = $BeansTable(this);
  late final $BeanBatchesTable beanBatches = $BeanBatchesTable(this);
  late final $GrindersTable grinders = $GrindersTable(this);
  late final $ShotRecordsTable shotRecords = $ShotRecordsTable(this);
  late final $SteamRecordsTable steamRecords = $SteamRecordsTable(this);
  late final $WorkflowsTable workflows = $WorkflowsTable(this);
  late final $ProfileRecordsTable profileRecords = $ProfileRecordsTable(this);
  late final BeanDao beanDao = BeanDao(this as AppDatabase);
  late final GrinderDao grinderDao = GrinderDao(this as AppDatabase);
  late final ShotDao shotDao = ShotDao(this as AppDatabase);
  late final SteamDao steamDao = SteamDao(this as AppDatabase);
  late final WorkflowDao workflowDao = WorkflowDao(this as AppDatabase);
  late final ProfileDao profileDao = ProfileDao(this as AppDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    beans,
    beanBatches,
    grinders,
    shotRecords,
    steamRecords,
    workflows,
    profileRecords,
  ];
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);
}

typedef $$BeansTableCreateCompanionBuilder =
    BeansCompanion Function({
      required String id,
      required String roaster,
      required String name,
      Value<String?> species,
      Value<bool> decaf,
      Value<String?> decafProcess,
      Value<String?> country,
      Value<String?> region,
      Value<String?> producer,
      Value<List<String>?> variety,
      Value<List<int>?> altitude,
      Value<String?> processing,
      Value<String?> notes,
      Value<bool> archived,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<Map<String, dynamic>?> extras,
      Value<int> rowid,
    });
typedef $$BeansTableUpdateCompanionBuilder =
    BeansCompanion Function({
      Value<String> id,
      Value<String> roaster,
      Value<String> name,
      Value<String?> species,
      Value<bool> decaf,
      Value<String?> decafProcess,
      Value<String?> country,
      Value<String?> region,
      Value<String?> producer,
      Value<List<String>?> variety,
      Value<List<int>?> altitude,
      Value<String?> processing,
      Value<String?> notes,
      Value<bool> archived,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<Map<String, dynamic>?> extras,
      Value<int> rowid,
    });

final class $$BeansTableReferences
    extends BaseReferences<_$AppDatabase, $BeansTable, Bean> {
  $$BeansTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$BeanBatchesTable, List<BeanBatche>>
  _beanBatchesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.beanBatches,
    aliasName: 'beans__id__bean_batches__bean_id',
  );

  $$BeanBatchesTableProcessedTableManager get beanBatchesRefs {
    final manager = $$BeanBatchesTableTableManager(
      $_db,
      $_db.beanBatches,
    ).filter((f) => f.beanId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_beanBatchesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$BeansTableFilterComposer extends Composer<_$AppDatabase, $BeansTable> {
  $$BeansTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roaster => $composableBuilder(
    column: $table.roaster,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get species => $composableBuilder(
    column: $table.species,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get decaf => $composableBuilder(
    column: $table.decaf,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get decafProcess => $composableBuilder(
    column: $table.decafProcess,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get country => $composableBuilder(
    column: $table.country,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get region => $composableBuilder(
    column: $table.region,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get producer => $composableBuilder(
    column: $table.producer,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>?, List<String>, String>
  get variety => $composableBuilder(
    column: $table.variety,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<List<int>?, List<int>, String> get altitude =>
      $composableBuilder(
        column: $table.altitude,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get processing => $composableBuilder(
    column: $table.processing,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get archived => $composableBuilder(
    column: $table.archived,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>?,
    Map<String, dynamic>,
    String
  >
  get extras => $composableBuilder(
    column: $table.extras,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  Expression<bool> beanBatchesRefs(
    Expression<bool> Function($$BeanBatchesTableFilterComposer f) f,
  ) {
    final $$BeanBatchesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.beanBatches,
      getReferencedColumn: (t) => t.beanId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BeanBatchesTableFilterComposer(
            $db: $db,
            $table: $db.beanBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BeansTableOrderingComposer
    extends Composer<_$AppDatabase, $BeansTable> {
  $$BeansTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roaster => $composableBuilder(
    column: $table.roaster,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get species => $composableBuilder(
    column: $table.species,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get decaf => $composableBuilder(
    column: $table.decaf,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get decafProcess => $composableBuilder(
    column: $table.decafProcess,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get country => $composableBuilder(
    column: $table.country,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get region => $composableBuilder(
    column: $table.region,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get producer => $composableBuilder(
    column: $table.producer,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variety => $composableBuilder(
    column: $table.variety,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get altitude => $composableBuilder(
    column: $table.altitude,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get processing => $composableBuilder(
    column: $table.processing,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get archived => $composableBuilder(
    column: $table.archived,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extras => $composableBuilder(
    column: $table.extras,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BeansTableAnnotationComposer
    extends Composer<_$AppDatabase, $BeansTable> {
  $$BeansTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get roaster =>
      $composableBuilder(column: $table.roaster, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get species =>
      $composableBuilder(column: $table.species, builder: (column) => column);

  GeneratedColumn<bool> get decaf =>
      $composableBuilder(column: $table.decaf, builder: (column) => column);

  GeneratedColumn<String> get decafProcess => $composableBuilder(
    column: $table.decafProcess,
    builder: (column) => column,
  );

  GeneratedColumn<String> get country =>
      $composableBuilder(column: $table.country, builder: (column) => column);

  GeneratedColumn<String> get region =>
      $composableBuilder(column: $table.region, builder: (column) => column);

  GeneratedColumn<String> get producer =>
      $composableBuilder(column: $table.producer, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<String>?, String> get variety =>
      $composableBuilder(column: $table.variety, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<int>?, String> get altitude =>
      $composableBuilder(column: $table.altitude, builder: (column) => column);

  GeneratedColumn<String> get processing => $composableBuilder(
    column: $table.processing,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<bool> get archived =>
      $composableBuilder(column: $table.archived, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String> get extras =>
      $composableBuilder(column: $table.extras, builder: (column) => column);

  Expression<T> beanBatchesRefs<T extends Object>(
    Expression<T> Function($$BeanBatchesTableAnnotationComposer a) f,
  ) {
    final $$BeanBatchesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.beanBatches,
      getReferencedColumn: (t) => t.beanId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BeanBatchesTableAnnotationComposer(
            $db: $db,
            $table: $db.beanBatches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BeansTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BeansTable,
          Bean,
          $$BeansTableFilterComposer,
          $$BeansTableOrderingComposer,
          $$BeansTableAnnotationComposer,
          $$BeansTableCreateCompanionBuilder,
          $$BeansTableUpdateCompanionBuilder,
          (Bean, $$BeansTableReferences),
          Bean,
          PrefetchHooks Function({bool beanBatchesRefs})
        > {
  $$BeansTableTableManager(_$AppDatabase db, $BeansTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BeansTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BeansTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BeansTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> roaster = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> species = const Value.absent(),
                Value<bool> decaf = const Value.absent(),
                Value<String?> decafProcess = const Value.absent(),
                Value<String?> country = const Value.absent(),
                Value<String?> region = const Value.absent(),
                Value<String?> producer = const Value.absent(),
                Value<List<String>?> variety = const Value.absent(),
                Value<List<int>?> altitude = const Value.absent(),
                Value<String?> processing = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<bool> archived = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<Map<String, dynamic>?> extras = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BeansCompanion(
                id: id,
                roaster: roaster,
                name: name,
                species: species,
                decaf: decaf,
                decafProcess: decafProcess,
                country: country,
                region: region,
                producer: producer,
                variety: variety,
                altitude: altitude,
                processing: processing,
                notes: notes,
                archived: archived,
                createdAt: createdAt,
                updatedAt: updatedAt,
                extras: extras,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String roaster,
                required String name,
                Value<String?> species = const Value.absent(),
                Value<bool> decaf = const Value.absent(),
                Value<String?> decafProcess = const Value.absent(),
                Value<String?> country = const Value.absent(),
                Value<String?> region = const Value.absent(),
                Value<String?> producer = const Value.absent(),
                Value<List<String>?> variety = const Value.absent(),
                Value<List<int>?> altitude = const Value.absent(),
                Value<String?> processing = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<bool> archived = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<Map<String, dynamic>?> extras = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BeansCompanion.insert(
                id: id,
                roaster: roaster,
                name: name,
                species: species,
                decaf: decaf,
                decafProcess: decafProcess,
                country: country,
                region: region,
                producer: producer,
                variety: variety,
                altitude: altitude,
                processing: processing,
                notes: notes,
                archived: archived,
                createdAt: createdAt,
                updatedAt: updatedAt,
                extras: extras,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$BeansTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({beanBatchesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (beanBatchesRefs) db.beanBatches],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (beanBatchesRefs)
                    await $_getPrefetchedData<Bean, $BeansTable, BeanBatche>(
                      currentTable: table,
                      referencedTable: $$BeansTableReferences
                          ._beanBatchesRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$BeansTableReferences(db, table, p0).beanBatchesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.beanId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$BeansTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BeansTable,
      Bean,
      $$BeansTableFilterComposer,
      $$BeansTableOrderingComposer,
      $$BeansTableAnnotationComposer,
      $$BeansTableCreateCompanionBuilder,
      $$BeansTableUpdateCompanionBuilder,
      (Bean, $$BeansTableReferences),
      Bean,
      PrefetchHooks Function({bool beanBatchesRefs})
    >;
typedef $$BeanBatchesTableCreateCompanionBuilder =
    BeanBatchesCompanion Function({
      required String id,
      required String beanId,
      Value<DateTime?> roastDate,
      Value<String?> roastLevel,
      Value<String?> harvestDate,
      Value<double?> qualityScore,
      Value<double?> price,
      Value<String?> currency,
      Value<double?> weight,
      Value<double?> weightRemaining,
      Value<DateTime?> buyDate,
      Value<DateTime?> openDate,
      Value<DateTime?> bestBeforeDate,
      Value<DateTime?> freezeDate,
      Value<DateTime?> unfreezeDate,
      Value<bool> frozen,
      Value<bool> archived,
      Value<String?> notes,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<Map<String, dynamic>?> extras,
      Value<int> rowid,
    });
typedef $$BeanBatchesTableUpdateCompanionBuilder =
    BeanBatchesCompanion Function({
      Value<String> id,
      Value<String> beanId,
      Value<DateTime?> roastDate,
      Value<String?> roastLevel,
      Value<String?> harvestDate,
      Value<double?> qualityScore,
      Value<double?> price,
      Value<String?> currency,
      Value<double?> weight,
      Value<double?> weightRemaining,
      Value<DateTime?> buyDate,
      Value<DateTime?> openDate,
      Value<DateTime?> bestBeforeDate,
      Value<DateTime?> freezeDate,
      Value<DateTime?> unfreezeDate,
      Value<bool> frozen,
      Value<bool> archived,
      Value<String?> notes,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<Map<String, dynamic>?> extras,
      Value<int> rowid,
    });

final class $$BeanBatchesTableReferences
    extends BaseReferences<_$AppDatabase, $BeanBatchesTable, BeanBatche> {
  $$BeanBatchesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $BeansTable _beanIdTable(_$AppDatabase db) =>
      db.beans.createAlias('bean_batches__bean_id__beans__id');

  $$BeansTableProcessedTableManager get beanId {
    final $_column = $_itemColumn<String>('bean_id')!;

    final manager = $$BeansTableTableManager(
      $_db,
      $_db.beans,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_beanIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$BeanBatchesTableFilterComposer
    extends Composer<_$AppDatabase, $BeanBatchesTable> {
  $$BeanBatchesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get roastDate => $composableBuilder(
    column: $table.roastDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roastLevel => $composableBuilder(
    column: $table.roastLevel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get harvestDate => $composableBuilder(
    column: $table.harvestDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get qualityScore => $composableBuilder(
    column: $table.qualityScore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get currency => $composableBuilder(
    column: $table.currency,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get weight => $composableBuilder(
    column: $table.weight,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get weightRemaining => $composableBuilder(
    column: $table.weightRemaining,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get buyDate => $composableBuilder(
    column: $table.buyDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get openDate => $composableBuilder(
    column: $table.openDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get bestBeforeDate => $composableBuilder(
    column: $table.bestBeforeDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get freezeDate => $composableBuilder(
    column: $table.freezeDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get unfreezeDate => $composableBuilder(
    column: $table.unfreezeDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get frozen => $composableBuilder(
    column: $table.frozen,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get archived => $composableBuilder(
    column: $table.archived,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>?,
    Map<String, dynamic>,
    String
  >
  get extras => $composableBuilder(
    column: $table.extras,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  $$BeansTableFilterComposer get beanId {
    final $$BeansTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.beanId,
      referencedTable: $db.beans,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BeansTableFilterComposer(
            $db: $db,
            $table: $db.beans,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$BeanBatchesTableOrderingComposer
    extends Composer<_$AppDatabase, $BeanBatchesTable> {
  $$BeanBatchesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get roastDate => $composableBuilder(
    column: $table.roastDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roastLevel => $composableBuilder(
    column: $table.roastLevel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get harvestDate => $composableBuilder(
    column: $table.harvestDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get qualityScore => $composableBuilder(
    column: $table.qualityScore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get currency => $composableBuilder(
    column: $table.currency,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get weight => $composableBuilder(
    column: $table.weight,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get weightRemaining => $composableBuilder(
    column: $table.weightRemaining,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get buyDate => $composableBuilder(
    column: $table.buyDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get openDate => $composableBuilder(
    column: $table.openDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get bestBeforeDate => $composableBuilder(
    column: $table.bestBeforeDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get freezeDate => $composableBuilder(
    column: $table.freezeDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get unfreezeDate => $composableBuilder(
    column: $table.unfreezeDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get frozen => $composableBuilder(
    column: $table.frozen,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get archived => $composableBuilder(
    column: $table.archived,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extras => $composableBuilder(
    column: $table.extras,
    builder: (column) => ColumnOrderings(column),
  );

  $$BeansTableOrderingComposer get beanId {
    final $$BeansTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.beanId,
      referencedTable: $db.beans,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BeansTableOrderingComposer(
            $db: $db,
            $table: $db.beans,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$BeanBatchesTableAnnotationComposer
    extends Composer<_$AppDatabase, $BeanBatchesTable> {
  $$BeanBatchesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get roastDate =>
      $composableBuilder(column: $table.roastDate, builder: (column) => column);

  GeneratedColumn<String> get roastLevel => $composableBuilder(
    column: $table.roastLevel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get harvestDate => $composableBuilder(
    column: $table.harvestDate,
    builder: (column) => column,
  );

  GeneratedColumn<double> get qualityScore => $composableBuilder(
    column: $table.qualityScore,
    builder: (column) => column,
  );

  GeneratedColumn<double> get price =>
      $composableBuilder(column: $table.price, builder: (column) => column);

  GeneratedColumn<String> get currency =>
      $composableBuilder(column: $table.currency, builder: (column) => column);

  GeneratedColumn<double> get weight =>
      $composableBuilder(column: $table.weight, builder: (column) => column);

  GeneratedColumn<double> get weightRemaining => $composableBuilder(
    column: $table.weightRemaining,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get buyDate =>
      $composableBuilder(column: $table.buyDate, builder: (column) => column);

  GeneratedColumn<DateTime> get openDate =>
      $composableBuilder(column: $table.openDate, builder: (column) => column);

  GeneratedColumn<DateTime> get bestBeforeDate => $composableBuilder(
    column: $table.bestBeforeDate,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get freezeDate => $composableBuilder(
    column: $table.freezeDate,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get unfreezeDate => $composableBuilder(
    column: $table.unfreezeDate,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get frozen =>
      $composableBuilder(column: $table.frozen, builder: (column) => column);

  GeneratedColumn<bool> get archived =>
      $composableBuilder(column: $table.archived, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String> get extras =>
      $composableBuilder(column: $table.extras, builder: (column) => column);

  $$BeansTableAnnotationComposer get beanId {
    final $$BeansTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.beanId,
      referencedTable: $db.beans,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BeansTableAnnotationComposer(
            $db: $db,
            $table: $db.beans,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$BeanBatchesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BeanBatchesTable,
          BeanBatche,
          $$BeanBatchesTableFilterComposer,
          $$BeanBatchesTableOrderingComposer,
          $$BeanBatchesTableAnnotationComposer,
          $$BeanBatchesTableCreateCompanionBuilder,
          $$BeanBatchesTableUpdateCompanionBuilder,
          (BeanBatche, $$BeanBatchesTableReferences),
          BeanBatche,
          PrefetchHooks Function({bool beanId})
        > {
  $$BeanBatchesTableTableManager(_$AppDatabase db, $BeanBatchesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BeanBatchesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BeanBatchesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BeanBatchesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> beanId = const Value.absent(),
                Value<DateTime?> roastDate = const Value.absent(),
                Value<String?> roastLevel = const Value.absent(),
                Value<String?> harvestDate = const Value.absent(),
                Value<double?> qualityScore = const Value.absent(),
                Value<double?> price = const Value.absent(),
                Value<String?> currency = const Value.absent(),
                Value<double?> weight = const Value.absent(),
                Value<double?> weightRemaining = const Value.absent(),
                Value<DateTime?> buyDate = const Value.absent(),
                Value<DateTime?> openDate = const Value.absent(),
                Value<DateTime?> bestBeforeDate = const Value.absent(),
                Value<DateTime?> freezeDate = const Value.absent(),
                Value<DateTime?> unfreezeDate = const Value.absent(),
                Value<bool> frozen = const Value.absent(),
                Value<bool> archived = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<Map<String, dynamic>?> extras = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BeanBatchesCompanion(
                id: id,
                beanId: beanId,
                roastDate: roastDate,
                roastLevel: roastLevel,
                harvestDate: harvestDate,
                qualityScore: qualityScore,
                price: price,
                currency: currency,
                weight: weight,
                weightRemaining: weightRemaining,
                buyDate: buyDate,
                openDate: openDate,
                bestBeforeDate: bestBeforeDate,
                freezeDate: freezeDate,
                unfreezeDate: unfreezeDate,
                frozen: frozen,
                archived: archived,
                notes: notes,
                createdAt: createdAt,
                updatedAt: updatedAt,
                extras: extras,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String beanId,
                Value<DateTime?> roastDate = const Value.absent(),
                Value<String?> roastLevel = const Value.absent(),
                Value<String?> harvestDate = const Value.absent(),
                Value<double?> qualityScore = const Value.absent(),
                Value<double?> price = const Value.absent(),
                Value<String?> currency = const Value.absent(),
                Value<double?> weight = const Value.absent(),
                Value<double?> weightRemaining = const Value.absent(),
                Value<DateTime?> buyDate = const Value.absent(),
                Value<DateTime?> openDate = const Value.absent(),
                Value<DateTime?> bestBeforeDate = const Value.absent(),
                Value<DateTime?> freezeDate = const Value.absent(),
                Value<DateTime?> unfreezeDate = const Value.absent(),
                Value<bool> frozen = const Value.absent(),
                Value<bool> archived = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<Map<String, dynamic>?> extras = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BeanBatchesCompanion.insert(
                id: id,
                beanId: beanId,
                roastDate: roastDate,
                roastLevel: roastLevel,
                harvestDate: harvestDate,
                qualityScore: qualityScore,
                price: price,
                currency: currency,
                weight: weight,
                weightRemaining: weightRemaining,
                buyDate: buyDate,
                openDate: openDate,
                bestBeforeDate: bestBeforeDate,
                freezeDate: freezeDate,
                unfreezeDate: unfreezeDate,
                frozen: frozen,
                archived: archived,
                notes: notes,
                createdAt: createdAt,
                updatedAt: updatedAt,
                extras: extras,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$BeanBatchesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({beanId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (beanId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.beanId,
                                referencedTable: $$BeanBatchesTableReferences
                                    ._beanIdTable(db),
                                referencedColumn: $$BeanBatchesTableReferences
                                    ._beanIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$BeanBatchesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BeanBatchesTable,
      BeanBatche,
      $$BeanBatchesTableFilterComposer,
      $$BeanBatchesTableOrderingComposer,
      $$BeanBatchesTableAnnotationComposer,
      $$BeanBatchesTableCreateCompanionBuilder,
      $$BeanBatchesTableUpdateCompanionBuilder,
      (BeanBatche, $$BeanBatchesTableReferences),
      BeanBatche,
      PrefetchHooks Function({bool beanId})
    >;
typedef $$GrindersTableCreateCompanionBuilder =
    GrindersCompanion Function({
      required String id,
      required String model,
      Value<String?> burrs,
      Value<double?> burrSize,
      Value<String?> burrType,
      Value<String?> notes,
      Value<bool> archived,
      Value<String> settingType,
      Value<List<String>?> settingValues,
      Value<double?> settingSmallStep,
      Value<double?> settingBigStep,
      Value<double?> rpmSmallStep,
      Value<double?> rpmBigStep,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<Map<String, dynamic>?> extras,
      Value<int> rowid,
    });
typedef $$GrindersTableUpdateCompanionBuilder =
    GrindersCompanion Function({
      Value<String> id,
      Value<String> model,
      Value<String?> burrs,
      Value<double?> burrSize,
      Value<String?> burrType,
      Value<String?> notes,
      Value<bool> archived,
      Value<String> settingType,
      Value<List<String>?> settingValues,
      Value<double?> settingSmallStep,
      Value<double?> settingBigStep,
      Value<double?> rpmSmallStep,
      Value<double?> rpmBigStep,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<Map<String, dynamic>?> extras,
      Value<int> rowid,
    });

class $$GrindersTableFilterComposer
    extends Composer<_$AppDatabase, $GrindersTable> {
  $$GrindersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get burrs => $composableBuilder(
    column: $table.burrs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get burrSize => $composableBuilder(
    column: $table.burrSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get burrType => $composableBuilder(
    column: $table.burrType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get archived => $composableBuilder(
    column: $table.archived,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get settingType => $composableBuilder(
    column: $table.settingType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>?, List<String>, String>
  get settingValues => $composableBuilder(
    column: $table.settingValues,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<double> get settingSmallStep => $composableBuilder(
    column: $table.settingSmallStep,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get settingBigStep => $composableBuilder(
    column: $table.settingBigStep,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get rpmSmallStep => $composableBuilder(
    column: $table.rpmSmallStep,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get rpmBigStep => $composableBuilder(
    column: $table.rpmBigStep,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>?,
    Map<String, dynamic>,
    String
  >
  get extras => $composableBuilder(
    column: $table.extras,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );
}

class $$GrindersTableOrderingComposer
    extends Composer<_$AppDatabase, $GrindersTable> {
  $$GrindersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get burrs => $composableBuilder(
    column: $table.burrs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get burrSize => $composableBuilder(
    column: $table.burrSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get burrType => $composableBuilder(
    column: $table.burrType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get archived => $composableBuilder(
    column: $table.archived,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get settingType => $composableBuilder(
    column: $table.settingType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get settingValues => $composableBuilder(
    column: $table.settingValues,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get settingSmallStep => $composableBuilder(
    column: $table.settingSmallStep,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get settingBigStep => $composableBuilder(
    column: $table.settingBigStep,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get rpmSmallStep => $composableBuilder(
    column: $table.rpmSmallStep,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get rpmBigStep => $composableBuilder(
    column: $table.rpmBigStep,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extras => $composableBuilder(
    column: $table.extras,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GrindersTableAnnotationComposer
    extends Composer<_$AppDatabase, $GrindersTable> {
  $$GrindersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<String> get burrs =>
      $composableBuilder(column: $table.burrs, builder: (column) => column);

  GeneratedColumn<double> get burrSize =>
      $composableBuilder(column: $table.burrSize, builder: (column) => column);

  GeneratedColumn<String> get burrType =>
      $composableBuilder(column: $table.burrType, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<bool> get archived =>
      $composableBuilder(column: $table.archived, builder: (column) => column);

  GeneratedColumn<String> get settingType => $composableBuilder(
    column: $table.settingType,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<List<String>?, String> get settingValues =>
      $composableBuilder(
        column: $table.settingValues,
        builder: (column) => column,
      );

  GeneratedColumn<double> get settingSmallStep => $composableBuilder(
    column: $table.settingSmallStep,
    builder: (column) => column,
  );

  GeneratedColumn<double> get settingBigStep => $composableBuilder(
    column: $table.settingBigStep,
    builder: (column) => column,
  );

  GeneratedColumn<double> get rpmSmallStep => $composableBuilder(
    column: $table.rpmSmallStep,
    builder: (column) => column,
  );

  GeneratedColumn<double> get rpmBigStep => $composableBuilder(
    column: $table.rpmBigStep,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String> get extras =>
      $composableBuilder(column: $table.extras, builder: (column) => column);
}

class $$GrindersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GrindersTable,
          Grinder,
          $$GrindersTableFilterComposer,
          $$GrindersTableOrderingComposer,
          $$GrindersTableAnnotationComposer,
          $$GrindersTableCreateCompanionBuilder,
          $$GrindersTableUpdateCompanionBuilder,
          (Grinder, BaseReferences<_$AppDatabase, $GrindersTable, Grinder>),
          Grinder,
          PrefetchHooks Function()
        > {
  $$GrindersTableTableManager(_$AppDatabase db, $GrindersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GrindersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GrindersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GrindersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> model = const Value.absent(),
                Value<String?> burrs = const Value.absent(),
                Value<double?> burrSize = const Value.absent(),
                Value<String?> burrType = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<bool> archived = const Value.absent(),
                Value<String> settingType = const Value.absent(),
                Value<List<String>?> settingValues = const Value.absent(),
                Value<double?> settingSmallStep = const Value.absent(),
                Value<double?> settingBigStep = const Value.absent(),
                Value<double?> rpmSmallStep = const Value.absent(),
                Value<double?> rpmBigStep = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<Map<String, dynamic>?> extras = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GrindersCompanion(
                id: id,
                model: model,
                burrs: burrs,
                burrSize: burrSize,
                burrType: burrType,
                notes: notes,
                archived: archived,
                settingType: settingType,
                settingValues: settingValues,
                settingSmallStep: settingSmallStep,
                settingBigStep: settingBigStep,
                rpmSmallStep: rpmSmallStep,
                rpmBigStep: rpmBigStep,
                createdAt: createdAt,
                updatedAt: updatedAt,
                extras: extras,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String model,
                Value<String?> burrs = const Value.absent(),
                Value<double?> burrSize = const Value.absent(),
                Value<String?> burrType = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<bool> archived = const Value.absent(),
                Value<String> settingType = const Value.absent(),
                Value<List<String>?> settingValues = const Value.absent(),
                Value<double?> settingSmallStep = const Value.absent(),
                Value<double?> settingBigStep = const Value.absent(),
                Value<double?> rpmSmallStep = const Value.absent(),
                Value<double?> rpmBigStep = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<Map<String, dynamic>?> extras = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GrindersCompanion.insert(
                id: id,
                model: model,
                burrs: burrs,
                burrSize: burrSize,
                burrType: burrType,
                notes: notes,
                archived: archived,
                settingType: settingType,
                settingValues: settingValues,
                settingSmallStep: settingSmallStep,
                settingBigStep: settingBigStep,
                rpmSmallStep: rpmSmallStep,
                rpmBigStep: rpmBigStep,
                createdAt: createdAt,
                updatedAt: updatedAt,
                extras: extras,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$GrindersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GrindersTable,
      Grinder,
      $$GrindersTableFilterComposer,
      $$GrindersTableOrderingComposer,
      $$GrindersTableAnnotationComposer,
      $$GrindersTableCreateCompanionBuilder,
      $$GrindersTableUpdateCompanionBuilder,
      (Grinder, BaseReferences<_$AppDatabase, $GrindersTable, Grinder>),
      Grinder,
      PrefetchHooks Function()
    >;
typedef $$ShotRecordsTableCreateCompanionBuilder =
    ShotRecordsCompanion Function({
      required String id,
      required DateTime timestamp,
      Value<String?> profileTitle,
      Value<String?> grinderId,
      Value<String?> grinderModel,
      Value<String?> grinderSetting,
      Value<String?> beanBatchId,
      Value<String?> coffeeName,
      Value<String?> coffeeRoaster,
      Value<double?> targetDoseWeight,
      Value<double?> targetYield,
      Value<double?> enjoyment,
      Value<String?> espressoNotes,
      Value<String?> stopReason,
      Value<DateTime?> createdAt,
      Value<DateTime?> updatedAt,
      required Map<String, dynamic> workflowJson,
      Value<Map<String, dynamic>?> annotationsJson,
      required String measurementsJson,
      Value<int> rowid,
    });
typedef $$ShotRecordsTableUpdateCompanionBuilder =
    ShotRecordsCompanion Function({
      Value<String> id,
      Value<DateTime> timestamp,
      Value<String?> profileTitle,
      Value<String?> grinderId,
      Value<String?> grinderModel,
      Value<String?> grinderSetting,
      Value<String?> beanBatchId,
      Value<String?> coffeeName,
      Value<String?> coffeeRoaster,
      Value<double?> targetDoseWeight,
      Value<double?> targetYield,
      Value<double?> enjoyment,
      Value<String?> espressoNotes,
      Value<String?> stopReason,
      Value<DateTime?> createdAt,
      Value<DateTime?> updatedAt,
      Value<Map<String, dynamic>> workflowJson,
      Value<Map<String, dynamic>?> annotationsJson,
      Value<String> measurementsJson,
      Value<int> rowid,
    });

class $$ShotRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $ShotRecordsTable> {
  $$ShotRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileTitle => $composableBuilder(
    column: $table.profileTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get grinderId => $composableBuilder(
    column: $table.grinderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get grinderModel => $composableBuilder(
    column: $table.grinderModel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get grinderSetting => $composableBuilder(
    column: $table.grinderSetting,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get beanBatchId => $composableBuilder(
    column: $table.beanBatchId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coffeeName => $composableBuilder(
    column: $table.coffeeName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coffeeRoaster => $composableBuilder(
    column: $table.coffeeRoaster,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get targetDoseWeight => $composableBuilder(
    column: $table.targetDoseWeight,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get targetYield => $composableBuilder(
    column: $table.targetYield,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get enjoyment => $composableBuilder(
    column: $table.enjoyment,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get espressoNotes => $composableBuilder(
    column: $table.espressoNotes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stopReason => $composableBuilder(
    column: $table.stopReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>,
    Map<String, dynamic>,
    String
  >
  get workflowJson => $composableBuilder(
    column: $table.workflowJson,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>?,
    Map<String, dynamic>,
    String
  >
  get annotationsJson => $composableBuilder(
    column: $table.annotationsJson,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get measurementsJson => $composableBuilder(
    column: $table.measurementsJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ShotRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $ShotRecordsTable> {
  $$ShotRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileTitle => $composableBuilder(
    column: $table.profileTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get grinderId => $composableBuilder(
    column: $table.grinderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get grinderModel => $composableBuilder(
    column: $table.grinderModel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get grinderSetting => $composableBuilder(
    column: $table.grinderSetting,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get beanBatchId => $composableBuilder(
    column: $table.beanBatchId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coffeeName => $composableBuilder(
    column: $table.coffeeName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coffeeRoaster => $composableBuilder(
    column: $table.coffeeRoaster,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get targetDoseWeight => $composableBuilder(
    column: $table.targetDoseWeight,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get targetYield => $composableBuilder(
    column: $table.targetYield,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get enjoyment => $composableBuilder(
    column: $table.enjoyment,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get espressoNotes => $composableBuilder(
    column: $table.espressoNotes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stopReason => $composableBuilder(
    column: $table.stopReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get workflowJson => $composableBuilder(
    column: $table.workflowJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get annotationsJson => $composableBuilder(
    column: $table.annotationsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get measurementsJson => $composableBuilder(
    column: $table.measurementsJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ShotRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ShotRecordsTable> {
  $$ShotRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<String> get profileTitle => $composableBuilder(
    column: $table.profileTitle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get grinderId =>
      $composableBuilder(column: $table.grinderId, builder: (column) => column);

  GeneratedColumn<String> get grinderModel => $composableBuilder(
    column: $table.grinderModel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get grinderSetting => $composableBuilder(
    column: $table.grinderSetting,
    builder: (column) => column,
  );

  GeneratedColumn<String> get beanBatchId => $composableBuilder(
    column: $table.beanBatchId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get coffeeName => $composableBuilder(
    column: $table.coffeeName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get coffeeRoaster => $composableBuilder(
    column: $table.coffeeRoaster,
    builder: (column) => column,
  );

  GeneratedColumn<double> get targetDoseWeight => $composableBuilder(
    column: $table.targetDoseWeight,
    builder: (column) => column,
  );

  GeneratedColumn<double> get targetYield => $composableBuilder(
    column: $table.targetYield,
    builder: (column) => column,
  );

  GeneratedColumn<double> get enjoyment =>
      $composableBuilder(column: $table.enjoyment, builder: (column) => column);

  GeneratedColumn<String> get espressoNotes => $composableBuilder(
    column: $table.espressoNotes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stopReason => $composableBuilder(
    column: $table.stopReason,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumnWithTypeConverter<Map<String, dynamic>, String>
  get workflowJson => $composableBuilder(
    column: $table.workflowJson,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String>
  get annotationsJson => $composableBuilder(
    column: $table.annotationsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get measurementsJson => $composableBuilder(
    column: $table.measurementsJson,
    builder: (column) => column,
  );
}

class $$ShotRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ShotRecordsTable,
          ShotRecord,
          $$ShotRecordsTableFilterComposer,
          $$ShotRecordsTableOrderingComposer,
          $$ShotRecordsTableAnnotationComposer,
          $$ShotRecordsTableCreateCompanionBuilder,
          $$ShotRecordsTableUpdateCompanionBuilder,
          (
            ShotRecord,
            BaseReferences<_$AppDatabase, $ShotRecordsTable, ShotRecord>,
          ),
          ShotRecord,
          PrefetchHooks Function()
        > {
  $$ShotRecordsTableTableManager(_$AppDatabase db, $ShotRecordsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ShotRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ShotRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ShotRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<DateTime> timestamp = const Value.absent(),
                Value<String?> profileTitle = const Value.absent(),
                Value<String?> grinderId = const Value.absent(),
                Value<String?> grinderModel = const Value.absent(),
                Value<String?> grinderSetting = const Value.absent(),
                Value<String?> beanBatchId = const Value.absent(),
                Value<String?> coffeeName = const Value.absent(),
                Value<String?> coffeeRoaster = const Value.absent(),
                Value<double?> targetDoseWeight = const Value.absent(),
                Value<double?> targetYield = const Value.absent(),
                Value<double?> enjoyment = const Value.absent(),
                Value<String?> espressoNotes = const Value.absent(),
                Value<String?> stopReason = const Value.absent(),
                Value<DateTime?> createdAt = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<Map<String, dynamic>> workflowJson = const Value.absent(),
                Value<Map<String, dynamic>?> annotationsJson =
                    const Value.absent(),
                Value<String> measurementsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ShotRecordsCompanion(
                id: id,
                timestamp: timestamp,
                profileTitle: profileTitle,
                grinderId: grinderId,
                grinderModel: grinderModel,
                grinderSetting: grinderSetting,
                beanBatchId: beanBatchId,
                coffeeName: coffeeName,
                coffeeRoaster: coffeeRoaster,
                targetDoseWeight: targetDoseWeight,
                targetYield: targetYield,
                enjoyment: enjoyment,
                espressoNotes: espressoNotes,
                stopReason: stopReason,
                createdAt: createdAt,
                updatedAt: updatedAt,
                workflowJson: workflowJson,
                annotationsJson: annotationsJson,
                measurementsJson: measurementsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required DateTime timestamp,
                Value<String?> profileTitle = const Value.absent(),
                Value<String?> grinderId = const Value.absent(),
                Value<String?> grinderModel = const Value.absent(),
                Value<String?> grinderSetting = const Value.absent(),
                Value<String?> beanBatchId = const Value.absent(),
                Value<String?> coffeeName = const Value.absent(),
                Value<String?> coffeeRoaster = const Value.absent(),
                Value<double?> targetDoseWeight = const Value.absent(),
                Value<double?> targetYield = const Value.absent(),
                Value<double?> enjoyment = const Value.absent(),
                Value<String?> espressoNotes = const Value.absent(),
                Value<String?> stopReason = const Value.absent(),
                Value<DateTime?> createdAt = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                required Map<String, dynamic> workflowJson,
                Value<Map<String, dynamic>?> annotationsJson =
                    const Value.absent(),
                required String measurementsJson,
                Value<int> rowid = const Value.absent(),
              }) => ShotRecordsCompanion.insert(
                id: id,
                timestamp: timestamp,
                profileTitle: profileTitle,
                grinderId: grinderId,
                grinderModel: grinderModel,
                grinderSetting: grinderSetting,
                beanBatchId: beanBatchId,
                coffeeName: coffeeName,
                coffeeRoaster: coffeeRoaster,
                targetDoseWeight: targetDoseWeight,
                targetYield: targetYield,
                enjoyment: enjoyment,
                espressoNotes: espressoNotes,
                stopReason: stopReason,
                createdAt: createdAt,
                updatedAt: updatedAt,
                workflowJson: workflowJson,
                annotationsJson: annotationsJson,
                measurementsJson: measurementsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ShotRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ShotRecordsTable,
      ShotRecord,
      $$ShotRecordsTableFilterComposer,
      $$ShotRecordsTableOrderingComposer,
      $$ShotRecordsTableAnnotationComposer,
      $$ShotRecordsTableCreateCompanionBuilder,
      $$ShotRecordsTableUpdateCompanionBuilder,
      (
        ShotRecord,
        BaseReferences<_$AppDatabase, $ShotRecordsTable, ShotRecord>,
      ),
      ShotRecord,
      PrefetchHooks Function()
    >;
typedef $$SteamRecordsTableCreateCompanionBuilder =
    SteamRecordsCompanion Function({
      required String id,
      required DateTime timestamp,
      required Map<String, dynamic> workflowJson,
      Value<Map<String, dynamic>?> annotationsJson,
      required String measurementsJson,
      Value<int> rowid,
    });
typedef $$SteamRecordsTableUpdateCompanionBuilder =
    SteamRecordsCompanion Function({
      Value<String> id,
      Value<DateTime> timestamp,
      Value<Map<String, dynamic>> workflowJson,
      Value<Map<String, dynamic>?> annotationsJson,
      Value<String> measurementsJson,
      Value<int> rowid,
    });

class $$SteamRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $SteamRecordsTable> {
  $$SteamRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>,
    Map<String, dynamic>,
    String
  >
  get workflowJson => $composableBuilder(
    column: $table.workflowJson,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>?,
    Map<String, dynamic>,
    String
  >
  get annotationsJson => $composableBuilder(
    column: $table.annotationsJson,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get measurementsJson => $composableBuilder(
    column: $table.measurementsJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SteamRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $SteamRecordsTable> {
  $$SteamRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get workflowJson => $composableBuilder(
    column: $table.workflowJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get annotationsJson => $composableBuilder(
    column: $table.annotationsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get measurementsJson => $composableBuilder(
    column: $table.measurementsJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SteamRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SteamRecordsTable> {
  $$SteamRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumnWithTypeConverter<Map<String, dynamic>, String>
  get workflowJson => $composableBuilder(
    column: $table.workflowJson,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String>
  get annotationsJson => $composableBuilder(
    column: $table.annotationsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get measurementsJson => $composableBuilder(
    column: $table.measurementsJson,
    builder: (column) => column,
  );
}

class $$SteamRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SteamRecordsTable,
          SteamRecord,
          $$SteamRecordsTableFilterComposer,
          $$SteamRecordsTableOrderingComposer,
          $$SteamRecordsTableAnnotationComposer,
          $$SteamRecordsTableCreateCompanionBuilder,
          $$SteamRecordsTableUpdateCompanionBuilder,
          (
            SteamRecord,
            BaseReferences<_$AppDatabase, $SteamRecordsTable, SteamRecord>,
          ),
          SteamRecord,
          PrefetchHooks Function()
        > {
  $$SteamRecordsTableTableManager(_$AppDatabase db, $SteamRecordsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SteamRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SteamRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SteamRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<DateTime> timestamp = const Value.absent(),
                Value<Map<String, dynamic>> workflowJson = const Value.absent(),
                Value<Map<String, dynamic>?> annotationsJson =
                    const Value.absent(),
                Value<String> measurementsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SteamRecordsCompanion(
                id: id,
                timestamp: timestamp,
                workflowJson: workflowJson,
                annotationsJson: annotationsJson,
                measurementsJson: measurementsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required DateTime timestamp,
                required Map<String, dynamic> workflowJson,
                Value<Map<String, dynamic>?> annotationsJson =
                    const Value.absent(),
                required String measurementsJson,
                Value<int> rowid = const Value.absent(),
              }) => SteamRecordsCompanion.insert(
                id: id,
                timestamp: timestamp,
                workflowJson: workflowJson,
                annotationsJson: annotationsJson,
                measurementsJson: measurementsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SteamRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SteamRecordsTable,
      SteamRecord,
      $$SteamRecordsTableFilterComposer,
      $$SteamRecordsTableOrderingComposer,
      $$SteamRecordsTableAnnotationComposer,
      $$SteamRecordsTableCreateCompanionBuilder,
      $$SteamRecordsTableUpdateCompanionBuilder,
      (
        SteamRecord,
        BaseReferences<_$AppDatabase, $SteamRecordsTable, SteamRecord>,
      ),
      SteamRecord,
      PrefetchHooks Function()
    >;
typedef $$WorkflowsTableCreateCompanionBuilder =
    WorkflowsCompanion Function({
      required String id,
      required Map<String, dynamic> workflowJson,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$WorkflowsTableUpdateCompanionBuilder =
    WorkflowsCompanion Function({
      Value<String> id,
      Value<Map<String, dynamic>> workflowJson,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$WorkflowsTableFilterComposer
    extends Composer<_$AppDatabase, $WorkflowsTable> {
  $$WorkflowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>,
    Map<String, dynamic>,
    String
  >
  get workflowJson => $composableBuilder(
    column: $table.workflowJson,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$WorkflowsTableOrderingComposer
    extends Composer<_$AppDatabase, $WorkflowsTable> {
  $$WorkflowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get workflowJson => $composableBuilder(
    column: $table.workflowJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WorkflowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $WorkflowsTable> {
  $$WorkflowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumnWithTypeConverter<Map<String, dynamic>, String>
  get workflowJson => $composableBuilder(
    column: $table.workflowJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$WorkflowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WorkflowsTable,
          Workflow,
          $$WorkflowsTableFilterComposer,
          $$WorkflowsTableOrderingComposer,
          $$WorkflowsTableAnnotationComposer,
          $$WorkflowsTableCreateCompanionBuilder,
          $$WorkflowsTableUpdateCompanionBuilder,
          (Workflow, BaseReferences<_$AppDatabase, $WorkflowsTable, Workflow>),
          Workflow,
          PrefetchHooks Function()
        > {
  $$WorkflowsTableTableManager(_$AppDatabase db, $WorkflowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WorkflowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WorkflowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WorkflowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<Map<String, dynamic>> workflowJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WorkflowsCompanion(
                id: id,
                workflowJson: workflowJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required Map<String, dynamic> workflowJson,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => WorkflowsCompanion.insert(
                id: id,
                workflowJson: workflowJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$WorkflowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WorkflowsTable,
      Workflow,
      $$WorkflowsTableFilterComposer,
      $$WorkflowsTableOrderingComposer,
      $$WorkflowsTableAnnotationComposer,
      $$WorkflowsTableCreateCompanionBuilder,
      $$WorkflowsTableUpdateCompanionBuilder,
      (Workflow, BaseReferences<_$AppDatabase, $WorkflowsTable, Workflow>),
      Workflow,
      PrefetchHooks Function()
    >;
typedef $$ProfileRecordsTableCreateCompanionBuilder =
    ProfileRecordsCompanion Function({
      required String id,
      required String metadataHash,
      required String compoundHash,
      Value<String?> parentId,
      Value<String> visibility,
      Value<bool> isDefault,
      required DateTime createdAt,
      required DateTime updatedAt,
      required Map<String, dynamic> profileJson,
      Value<Map<String, dynamic>?> metadata,
      Value<int> rowid,
    });
typedef $$ProfileRecordsTableUpdateCompanionBuilder =
    ProfileRecordsCompanion Function({
      Value<String> id,
      Value<String> metadataHash,
      Value<String> compoundHash,
      Value<String?> parentId,
      Value<String> visibility,
      Value<bool> isDefault,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<Map<String, dynamic>> profileJson,
      Value<Map<String, dynamic>?> metadata,
      Value<int> rowid,
    });

class $$ProfileRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $ProfileRecordsTable> {
  $$ProfileRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metadataHash => $composableBuilder(
    column: $table.metadataHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get compoundHash => $composableBuilder(
    column: $table.compoundHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get visibility => $composableBuilder(
    column: $table.visibility,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>,
    Map<String, dynamic>,
    String
  >
  get profileJson => $composableBuilder(
    column: $table.profileJson,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<
    Map<String, dynamic>?,
    Map<String, dynamic>,
    String
  >
  get metadata => $composableBuilder(
    column: $table.metadata,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );
}

class $$ProfileRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $ProfileRecordsTable> {
  $$ProfileRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadataHash => $composableBuilder(
    column: $table.metadataHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get compoundHash => $composableBuilder(
    column: $table.compoundHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get visibility => $composableBuilder(
    column: $table.visibility,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileJson => $composableBuilder(
    column: $table.profileJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadata => $composableBuilder(
    column: $table.metadata,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProfileRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProfileRecordsTable> {
  $$ProfileRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get metadataHash => $composableBuilder(
    column: $table.metadataHash,
    builder: (column) => column,
  );

  GeneratedColumn<String> get compoundHash => $composableBuilder(
    column: $table.compoundHash,
    builder: (column) => column,
  );

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<String> get visibility => $composableBuilder(
    column: $table.visibility,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isDefault =>
      $composableBuilder(column: $table.isDefault, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumnWithTypeConverter<Map<String, dynamic>, String>
  get profileJson => $composableBuilder(
    column: $table.profileJson,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<Map<String, dynamic>?, String>
  get metadata =>
      $composableBuilder(column: $table.metadata, builder: (column) => column);
}

class $$ProfileRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProfileRecordsTable,
          ProfileRecord,
          $$ProfileRecordsTableFilterComposer,
          $$ProfileRecordsTableOrderingComposer,
          $$ProfileRecordsTableAnnotationComposer,
          $$ProfileRecordsTableCreateCompanionBuilder,
          $$ProfileRecordsTableUpdateCompanionBuilder,
          (
            ProfileRecord,
            BaseReferences<_$AppDatabase, $ProfileRecordsTable, ProfileRecord>,
          ),
          ProfileRecord,
          PrefetchHooks Function()
        > {
  $$ProfileRecordsTableTableManager(
    _$AppDatabase db,
    $ProfileRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfileRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfileRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProfileRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> metadataHash = const Value.absent(),
                Value<String> compoundHash = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<String> visibility = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<Map<String, dynamic>> profileJson = const Value.absent(),
                Value<Map<String, dynamic>?> metadata = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfileRecordsCompanion(
                id: id,
                metadataHash: metadataHash,
                compoundHash: compoundHash,
                parentId: parentId,
                visibility: visibility,
                isDefault: isDefault,
                createdAt: createdAt,
                updatedAt: updatedAt,
                profileJson: profileJson,
                metadata: metadata,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String metadataHash,
                required String compoundHash,
                Value<String?> parentId = const Value.absent(),
                Value<String> visibility = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                required Map<String, dynamic> profileJson,
                Value<Map<String, dynamic>?> metadata = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfileRecordsCompanion.insert(
                id: id,
                metadataHash: metadataHash,
                compoundHash: compoundHash,
                parentId: parentId,
                visibility: visibility,
                isDefault: isDefault,
                createdAt: createdAt,
                updatedAt: updatedAt,
                profileJson: profileJson,
                metadata: metadata,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ProfileRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProfileRecordsTable,
      ProfileRecord,
      $$ProfileRecordsTableFilterComposer,
      $$ProfileRecordsTableOrderingComposer,
      $$ProfileRecordsTableAnnotationComposer,
      $$ProfileRecordsTableCreateCompanionBuilder,
      $$ProfileRecordsTableUpdateCompanionBuilder,
      (
        ProfileRecord,
        BaseReferences<_$AppDatabase, $ProfileRecordsTable, ProfileRecord>,
      ),
      ProfileRecord,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$BeansTableTableManager get beans =>
      $$BeansTableTableManager(_db, _db.beans);
  $$BeanBatchesTableTableManager get beanBatches =>
      $$BeanBatchesTableTableManager(_db, _db.beanBatches);
  $$GrindersTableTableManager get grinders =>
      $$GrindersTableTableManager(_db, _db.grinders);
  $$ShotRecordsTableTableManager get shotRecords =>
      $$ShotRecordsTableTableManager(_db, _db.shotRecords);
  $$SteamRecordsTableTableManager get steamRecords =>
      $$SteamRecordsTableTableManager(_db, _db.steamRecords);
  $$WorkflowsTableTableManager get workflows =>
      $$WorkflowsTableTableManager(_db, _db.workflows);
  $$ProfileRecordsTableTableManager get profileRecords =>
      $$ProfileRecordsTableTableManager(_db, _db.profileRecords);
}
