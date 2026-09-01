import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/database/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  EquipmentRecordsCompanion makeEquipment({
    String id = 'eq-1',
    String type = 'basket',
    String name = 'Test Basket',
    bool archived = false,
  }) {
    final now = DateTime.now();
    return EquipmentRecordsCompanion(
      id: Value(id),
      type: Value(type),
      name: Value(name),
      archived: Value(archived),
      createdAt: Value(now),
      updatedAt: Value(now),
    );
  }

  test('inserts and retrieves equipment', () async {
    await db.equipmentDao.insertEquipment(makeEquipment());
    final equipment = await db.equipmentDao.getAllEquipment();
    expect(equipment, hasLength(1));
    expect(equipment.first.name, 'Test Basket');
  });

  test('filters archived equipment by default', () async {
    await db.equipmentDao.insertEquipment(makeEquipment(id: 'e1'));
    await db.equipmentDao.insertEquipment(
      makeEquipment(id: 'e2', archived: true),
    );

    final active = await db.equipmentDao.getAllEquipment();
    expect(active, hasLength(1));

    final all = await db.equipmentDao.getAllEquipment(includeArchived: true);
    expect(all, hasLength(2));
  });

  test('filters by type', () async {
    await db.equipmentDao.insertEquipment(
      makeEquipment(id: 'e1', type: 'basket'),
    );
    await db.equipmentDao.insertEquipment(
      makeEquipment(id: 'e2', type: 'portafilter'),
    );

    final baskets = await db.equipmentDao.getAllEquipment(type: 'basket');
    expect(baskets, hasLength(1));
    expect(baskets.first.type, 'basket');
  });

  test('gets equipment by ID', () async {
    await db.equipmentDao.insertEquipment(
      makeEquipment(id: 'e1', name: 'IMS Superfine'),
    );
    final equipment = await db.equipmentDao.getEquipmentById('e1');
    expect(equipment, isNotNull);
    expect(equipment!.name, 'IMS Superfine');
  });

  test('updates equipment', () async {
    await db.equipmentDao.insertEquipment(
      makeEquipment(id: 'e1', name: 'Old'),
    );
    await db.equipmentDao.updateEquipment(
      EquipmentRecordsCompanion(
        id: const Value('e1'),
        name: const Value('New'),
        updatedAt: Value(DateTime.now()),
      ),
    );
    final equipment = await db.equipmentDao.getEquipmentById('e1');
    expect(equipment!.name, 'New');
  });

  test('deletes equipment', () async {
    await db.equipmentDao.insertEquipment(makeEquipment(id: 'e1'));
    await db.equipmentDao.deleteEquipment('e1');
    final equipment = await db.equipmentDao.getAllEquipment(
      includeArchived: true,
    );
    expect(equipment, isEmpty);
  });

  test('watches equipment changes', () async {
    final stream = db.equipmentDao.watchAllEquipment();
    await db.equipmentDao.insertEquipment(makeEquipment(id: 'e1'));
    final equipment = await stream.first;
    expect(equipment, hasLength(1));
  });

  test('stores tools list', () async {
    final now = DateTime.now();
    await db.equipmentDao.insertEquipment(
      EquipmentRecordsCompanion(
        id: const Value('e1'),
        type: const Value('basket'),
        name: const Value('DYE2'),
        tools: const Value(['WDT tool', 'Puck screen']),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );

    final equipment = await db.equipmentDao.getEquipmentById('e1');
    expect(equipment!.tools, ['WDT tool', 'Puck screen']);
  });
}
