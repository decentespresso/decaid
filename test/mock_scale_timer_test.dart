import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';

void main() {
  group('MockScale timer', () {
    late MockScale scale;

    setUp(() {
      scale = MockScale();
    });

    test('timer starts at null', () async {
      final snapshot = await scale.currentSnapshot.first;
      expect(snapshot.timerValue, isNull);
    });

    test('startTimer begins tracking elapsed time', () async {
      await scale.startTimer();
      // Wait for at least one snapshot cycle (200ms) plus some buffer
      await Future.delayed(Duration(milliseconds: 350));
      final snapshot = await scale.currentSnapshot.first;
      expect(snapshot.timerValue, isNotNull);
      expect(snapshot.timerValue!.inMilliseconds, greaterThan(0));
    });

    test('stopTimer freezes the elapsed time', () async {
      await scale.startTimer();
      await Future.delayed(Duration(milliseconds: 300));
      await scale.stopTimer();
      final snapshot1 = await scale.currentSnapshot.first;
      final frozenValue = snapshot1.timerValue;
      expect(frozenValue, isNotNull);

      await Future.delayed(Duration(milliseconds: 300));
      final snapshot2 = await scale.currentSnapshot.first;
      expect(snapshot2.timerValue, equals(frozenValue));
    });

    test('resetTimer clears the elapsed time', () async {
      await scale.startTimer();
      await Future.delayed(Duration(milliseconds: 300));
      await scale.resetTimer();
      final snapshot = await scale.currentSnapshot.first;
      expect(snapshot.timerValue, isNull);
    });
  });
}
