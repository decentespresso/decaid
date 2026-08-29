import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/equipment.dart';

void main() {
  final now = DateTime(2026, 1, 15, 10, 0, 0);

  group('EquipmentType', () {
    test('fromString parses known values', () {
      expect(EquipmentType.fromString('basket'), EquipmentType.basket);
      expect(
        EquipmentType.fromString('portafilter'),
        EquipmentType.portafilter,
      );
      expect(EquipmentType.fromString('dripper'), EquipmentType.dripper);
      expect(EquipmentType.fromString('other'), EquipmentType.other);
    });

    test('fromString defaults to other for unknown', () {
      expect(EquipmentType.fromString('unknown'), EquipmentType.other);
    });
  });

  group('Equipment', () {
    test('round-trip serialization with all fields', () {
      final equipment = Equipment(
        id: 'eq-1',
        type: EquipmentType.basket,
        name: 'IMS Superfine 18g',
        style: 'double',
        diameterMm: 58.0,
        notes: 'Precision basket',
        archived: false,
        tools: ['WDT tool'],
        createdAt: now,
        updatedAt: now,
        extras: {'bcUuid': 'abc-123'},
      );

      final json = equipment.toJson();
      final restored = Equipment.fromJson(json);

      expect(restored.id, 'eq-1');
      expect(restored.type, EquipmentType.basket);
      expect(restored.name, 'IMS Superfine 18g');
      expect(restored.style, 'double');
      expect(restored.diameterMm, 58.0);
      expect(restored.notes, 'Precision basket');
      expect(restored.archived, false);
      expect(restored.tools, ['WDT tool']);
      expect(restored.extras, {'bcUuid': 'abc-123'});
    });

    test('nullable fields omitted from JSON', () {
      final equipment = Equipment(
        id: 'eq-2',
        type: EquipmentType.portafilter,
        name: 'Bottomless Portafilter',
        createdAt: now,
        updatedAt: now,
      );

      final json = equipment.toJson();
      expect(json.containsKey('style'), false);
      expect(json.containsKey('diameterMm'), false);
      expect(json.containsKey('notes'), false);
      expect(json.containsKey('tools'), false);
      expect(json.containsKey('extras'), false);
      expect(json['type'], 'portafilter');
      expect(json['archived'], false);
    });

    test('create factory generates id and timestamps', () {
      final equipment = Equipment.create(
        type: EquipmentType.dripper,
        name: 'V60',
      );

      expect(equipment.id, isNotEmpty);
      expect(equipment.createdAt, isNotNull);
      expect(equipment.updatedAt, isNotNull);
      expect(equipment.archived, false);
      expect(equipment.type, EquipmentType.dripper);
    });

    test('copyWith preserves unchanged fields', () {
      final equipment = Equipment(
        id: 'eq-3',
        type: EquipmentType.basket,
        name: 'Stock Double',
        diameterMm: 58.0,
        createdAt: now,
        updatedAt: now,
      );

      final updated = equipment.copyWith(diameterMm: 58.5);

      expect(updated.id, 'eq-3');
      expect(updated.name, 'Stock Double');
      expect(updated.type, EquipmentType.basket);
      expect(updated.diameterMm, 58.5);
    });

    test('fromJson handles int values for doubles', () {
      final json = {
        'id': 'eq-4',
        'type': 'basket',
        'name': 'Test',
        'diameterMm': 58,
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
      };

      final equipment = Equipment.fromJson(json);
      expect(equipment.diameterMm, 58.0);
    });

    test('fromJson defaults missing type to other', () {
      final json = {
        'id': 'eq-5',
        'name': 'Unlabelled',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
      };

      final equipment = Equipment.fromJson(json);
      expect(equipment.type, EquipmentType.other);
    });
  });
}
