import 'package:test/test.dart';
import 'package:chess_review_core/chess_review_core.dart';

void main() {
  group('Test 1: WinPercent vectors (tolerance +/- 0.1)', () {
    test('cp 0 -> 50.0', () {
      expect(WinPercent.fromCp(0), closeTo(50.0, 0.1));
    });

    test('cp 100 -> 59.1', () {
      expect(WinPercent.fromCp(100), closeTo(59.1, 0.1));
    });

    test('cp -100 -> 40.9', () {
      expect(WinPercent.fromCp(-100), closeTo(40.9, 0.1));
    });

    test('cp 300 -> 75.1', () {
      expect(WinPercent.fromCp(300), closeTo(75.1, 0.1));
    });

    test('cp 600 -> 90.1', () {
      expect(WinPercent.fromCp(600), closeTo(90.1, 0.1));
    });

    test('clamps cp beyond +/- 1000', () {
      final at1000 = WinPercent.fromCp(1000);
      final at1500 = WinPercent.fromCp(1500);
      expect(at1500, equals(at1000));

      final atMinus1000 = WinPercent.fromCp(-1000);
      final atMinus2000 = WinPercent.fromCp(-2000);
      expect(atMinus2000, equals(atMinus1000));
    });

    test('explicit mate branches (never via cp)', () {
      expect(WinPercent.fromMate(1), equals(100.0));
      expect(WinPercent.fromMate(5), equals(100.0));
      expect(WinPercent.fromMate(-1), equals(0.0));
      expect(WinPercent.fromMate(-3), equals(0.0));
    });
  });

  group('Test 2: MoveAccuracy vectors for deltaW {0, 5, 10, 20, 40}', () {
    test('bonus 0 -> 100.0 / 79.8 / 63.6 / 40.0 / 14.9', () {
      const bonus = 0.0;
      expect(MoveAccuracy.calculate(deltaW: 0, bonus: bonus), closeTo(100.0, 0.1));
      expect(MoveAccuracy.calculate(deltaW: 5, bonus: bonus), closeTo(79.8, 0.1));
      expect(MoveAccuracy.calculate(deltaW: 10, bonus: bonus), closeTo(63.6, 0.1));
      expect(MoveAccuracy.calculate(deltaW: 20, bonus: bonus), closeTo(40.0, 0.1));
      expect(MoveAccuracy.calculate(deltaW: 40, bonus: bonus), closeTo(14.9, 0.1));
    });

    test('bonus 1 -> 100.0 / 80.8 / 64.6 / 41.0 / 15.9', () {
      const bonus = 1.0;
      expect(MoveAccuracy.calculate(deltaW: 0, bonus: bonus), closeTo(100.0, 0.1));
      expect(MoveAccuracy.calculate(deltaW: 5, bonus: bonus), closeTo(80.8, 0.1));
      expect(MoveAccuracy.calculate(deltaW: 10, bonus: bonus), closeTo(64.6, 0.1));
      expect(MoveAccuracy.calculate(deltaW: 20, bonus: bonus), closeTo(41.0, 0.1));
      expect(MoveAccuracy.calculate(deltaW: 40, bonus: bonus), closeTo(15.9, 0.1));
    });
  });

  group('Test 3: Accuracy monotonicity and extreme safety', () {
    test('accuracy never increases as deltaW grows', () {
      var prev = 100.0;
      for (var d = 0.0; d <= 100.0; d += 0.25) {
        final acc = MoveAccuracy.calculate(deltaW: d, bonus: 1.0);
        expect(acc, lessThanOrEqualTo(prev + 1e-9),
            reason: 'Failed monotonicity at deltaW=$d: prev=$prev, current=$acc');
        prev = acc;
      }
    });

    test('no NaN at extreme inputs', () {
      final negativeDelta = MoveAccuracy.calculate(deltaW: -5.0);
      expect(negativeDelta.isNaN, isFalse);
      expect(negativeDelta, equals(100.0));

      final zeroDelta = MoveAccuracy.calculate(deltaW: 0.0);
      expect(zeroDelta.isNaN, isFalse);
      expect(zeroDelta, equals(100.0));

      final maxDelta = MoveAccuracy.calculate(deltaW: 100.0);
      expect(maxDelta.isNaN, isFalse);
      expect(maxDelta, greaterThanOrEqualTo(0.0));

      final hugeDelta = MoveAccuracy.calculate(deltaW: 100000.0);
      expect(hugeDelta.isNaN, isFalse);
      expect(hugeDelta, equals(0.0));
    });
  });
}
