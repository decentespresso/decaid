import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart';

import '../helpers/shot_event_storage.dart';

void main() {
  for (final operation in ['store', 'persist', 'update']) {
    test('$operation notifies only after a successful write', () async {
      final storage = ShotEventStorage()..writeGate = Completer<void>();
      final controller = PersistenceController(storageService: storage);
      addTearDown(controller.dispose);
      final stored = <String>[];
      final updated = <ShotRecord>[];
      final patches = <Map<String, dynamic>>[];
      var changes = 0;
      final subscription = controller.shotsChanged.listen((_) => changes++);
      addTearDown(subscription.cancel);
      controller.onShotStored = (id) {
        expect(storage.shots[id], isNotNull);
        stored.add(id);
      };
      controller.onShotUpdated = (record, patch) {
        expect(storage.shots[record.id], same(record));
        updated.add(record);
        patches.add(patch);
      };
      final record = eventShot();
      final patch = <String, dynamic>{
        'annotations': {'espressoNotes': 'old'},
      };
      Future<void> write() => switch (operation) {
        'store' => controller.storeShot(record),
        'persist' => controller.persistShot(record),
        _ => controller.updateShot(record, patch: patch),
      };

      final pending = write();
      await Future<void>.delayed(Duration.zero);
      expect(stored, isEmpty);
      expect(updated, isEmpty);
      expect(changes, 0);
      storage.writeGate!.complete();
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(stored, operation == 'update' ? isEmpty : ['shot-1']);
      expect(updated, operation == 'update' ? [record] : isEmpty);
      expect(patches, operation == 'update' ? [patch] : isEmpty);
      expect(changes, 1);

      storage.failedIds.add(record.id);
      if (operation == 'persist') {
        await write();
      } else {
        await expectLater(write(), throwsStateError);
      }
      await Future<void>.delayed(Duration.zero);
      expect(stored, operation == 'update' ? isEmpty : ['shot-1']);
      expect(updated, operation == 'update' ? [record] : isEmpty);
      expect(changes, 1);
    });
  }
}
