import 'package:reaprime/src/models/data/utils.dart';
import 'package:uuid/uuid.dart';

class Bean {
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
    this.decaf = false,
    this.decafProcess,
    this.country,
    this.region,
    this.producer,
    this.variety,
    this.altitude,
    this.processing,
    this.notes,
    this.archived = false,
    required this.createdAt,
    required this.updatedAt,
    this.extras,
  });

  factory Bean.create({
    required String roaster,
    required String name,
    String? species,
    bool decaf = false,
    String? decafProcess,
    String? country,
    String? region,
    String? producer,
    List<String>? variety,
    List<int>? altitude,
    String? processing,
    String? notes,
    Map<String, dynamic>? extras,
  }) {
    final now = DateTime.now();
    return Bean(
      id: const Uuid().v4(),
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
      createdAt: now,
      updatedAt: now,
      extras: extras,
    );
  }

  factory Bean.fromJson(Map<String, dynamic> json) {
    return Bean(
      id: json['id'] as String,
      roaster: json['roaster'] as String,
      name: json['name'] as String,
      species: json['species'] as String?,
      decaf: json['decaf'] as bool? ?? false,
      decafProcess: json['decafProcess'] as String?,
      country: json['country'] as String?,
      region: json['region'] as String?,
      producer: json['producer'] as String?,
      variety: (json['variety'] as List?)?.cast<String>(),
      altitude: (json['altitude'] as List?)?.map((e) => parseInt(e)).toList(),
      processing: json['processing'] as String?,
      notes: json['notes'] as String?,
      archived: json['archived'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      extras: json['extras'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'roaster': roaster,
      'name': name,
      if (species != null) 'species': species,
      'decaf': decaf,
      if (decafProcess != null) 'decafProcess': decafProcess,
      if (country != null) 'country': country,
      if (region != null) 'region': region,
      if (producer != null) 'producer': producer,
      if (variety != null) 'variety': variety,
      if (altitude != null) 'altitude': altitude,
      if (processing != null) 'processing': processing,
      if (notes != null) 'notes': notes,
      'archived': archived,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (extras != null) 'extras': extras,
    };
  }

  Bean copyWith({
    String? roaster,
    String? name,
    String? species,
    bool? decaf,
    String? decafProcess,
    String? country,
    String? region,
    String? producer,
    List<String>? variety,
    List<int>? altitude,
    String? processing,
    String? notes,
    bool? archived,
    Map<String, dynamic>? extras,
  }) {
    return Bean(
      id: id,
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
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      extras: extras ?? this.extras,
    );
  }

  @override
  String toString() => 'Bean($roaster $name, id: $id)';
}

class BeanBatch {
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

  const BeanBatch({
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
    this.frozen = false,
    this.archived = false,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
    this.extras,
  });

  factory BeanBatch.create({
    required String beanId,
    DateTime? roastDate,
    String? roastLevel,
    String? harvestDate,
    double? qualityScore,
    double? price,
    String? currency,
    double? weight,
    DateTime? buyDate,
    DateTime? openDate,
    DateTime? bestBeforeDate,
    DateTime? freezeDate,
    DateTime? unfreezeDate,
    bool frozen = false,
    String? notes,
    Map<String, dynamic>? extras,
  }) {
    final now = DateTime.now();
    return BeanBatch(
      id: const Uuid().v4(),
      beanId: beanId,
      roastDate: roastDate,
      roastLevel: roastLevel,
      harvestDate: harvestDate,
      qualityScore: qualityScore,
      price: price,
      currency: currency,
      weight: weight,
      weightRemaining: weight,
      buyDate: buyDate,
      openDate: openDate,
      bestBeforeDate: bestBeforeDate,
      freezeDate: freezeDate,
      unfreezeDate: unfreezeDate,
      frozen: frozen,
      notes: notes,
      createdAt: now,
      updatedAt: now,
      extras: extras,
    );
  }

  factory BeanBatch.fromJson(Map<String, dynamic> json) {
    return BeanBatch(
      id: json['id'] as String,
      beanId: json['beanId'] as String,
      roastDate: json['roastDate'] != null
          ? DateTime.parse(json['roastDate'] as String)
          : null,
      roastLevel: json['roastLevel'] as String?,
      harvestDate: json['harvestDate'] as String?,
      qualityScore: parseOptionalDouble(json['qualityScore']),
      price: parseOptionalDouble(json['price']),
      currency: json['currency'] as String?,
      weight: parseOptionalDouble(json['weight']),
      weightRemaining: parseOptionalDouble(json['weightRemaining']),
      buyDate: json['buyDate'] != null
          ? DateTime.parse(json['buyDate'] as String)
          : null,
      openDate: json['openDate'] != null
          ? DateTime.parse(json['openDate'] as String)
          : null,
      bestBeforeDate: json['bestBeforeDate'] != null
          ? DateTime.parse(json['bestBeforeDate'] as String)
          : null,
      freezeDate: json['freezeDate'] != null
          ? DateTime.parse(json['freezeDate'] as String)
          : null,
      unfreezeDate: json['unfreezeDate'] != null
          ? DateTime.parse(json['unfreezeDate'] as String)
          : null,
      frozen: json['frozen'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
      notes: json['notes'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      extras: json['extras'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'beanId': beanId,
      if (roastDate != null) 'roastDate': roastDate!.toIso8601String(),
      if (roastLevel != null) 'roastLevel': roastLevel,
      if (harvestDate != null) 'harvestDate': harvestDate,
      if (qualityScore != null) 'qualityScore': qualityScore,
      if (price != null) 'price': price,
      if (currency != null) 'currency': currency,
      if (weight != null) 'weight': weight,
      if (weightRemaining != null) 'weightRemaining': weightRemaining,
      if (buyDate != null) 'buyDate': buyDate!.toIso8601String(),
      if (openDate != null) 'openDate': openDate!.toIso8601String(),
      if (bestBeforeDate != null)
        'bestBeforeDate': bestBeforeDate!.toIso8601String(),
      if (freezeDate != null) 'freezeDate': freezeDate!.toIso8601String(),
      if (unfreezeDate != null) 'unfreezeDate': unfreezeDate!.toIso8601String(),
      'frozen': frozen,
      'archived': archived,
      if (notes != null) 'notes': notes,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (extras != null) 'extras': extras,
    };
  }

  BeanBatch copyWith({
    String? beanId,
    DateTime? roastDate,
    String? roastLevel,
    String? harvestDate,
    double? qualityScore,
    double? price,
    String? currency,
    double? weight,
    double? weightRemaining,
    DateTime? buyDate,
    DateTime? openDate,
    DateTime? bestBeforeDate,
    DateTime? freezeDate,
    DateTime? unfreezeDate,
    bool? frozen,
    bool? archived,
    String? notes,
    Map<String, dynamic>? extras,
  }) {
    return BeanBatch(
      id: id,
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
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      extras: extras ?? this.extras,
    );
  }

  @override
  String toString() => 'BeanBatch($id, bean: $beanId)';
}
