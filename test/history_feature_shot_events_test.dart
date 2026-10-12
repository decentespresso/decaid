import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/history_feature/history_feature.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/shot_event_storage.dart';

void main() {
  for (final notes in ['new notes', '']) {
    testWidgets('History saves an annotations patch for "$notes"', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final record = eventShot();
      final storage = ShotEventStorage()..shots[record.id] = record;
      final controller = PersistenceController(storageService: storage);
      addTearDown(controller.dispose);
      final events = <Map<String, dynamic>>[];
      controller.onShotUpdated = (shot, patch) => events.add({
        'id': shot.id,
        'shot': shot.toJsonWithoutMeasurements(),
        'patch': patch,
      });
      await tester.pumpWidget(
        ShadApp(
          home: HistoryFeature(
            persistenceController: controller,
            workflowController: WorkflowController(),
            selectedShot: jsonEncode(record.toJson()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Edit shot notes'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, notes);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(events, hasLength(1));
      expect(events.single['id'], record.id);
      expect(
        events.single['shot'],
        storage.shots[record.id]!.toJsonWithoutMeasurements(),
      );
      expect(events.single['shot']['annotations']['espressoNotes'], notes);
      expect(events.single['patch'], {
        'annotations': {'espressoNotes': notes},
      });
      expect(events.single['shot'].containsKey('measurements'), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
