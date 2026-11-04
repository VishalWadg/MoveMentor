import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/domain/analysis/move_classifier.dart';
import 'package:movementor/src/domain/analysis/phase_detector.dart';
import 'package:movementor/src/domain/analysis/win_accuracy_calculator.dart';
import 'package:movementor/src/domain/chess/chess_models.dart';

void main() {
  group('Part 30.2 Golden Vectors (tolerance ±0.1)', () {
    test('T-ACC-01: Win% from centipawns, mover perspective', () {
      expect(
        WinAccuracyCalculator.winPercentFromScore(cp: 0),
        closeTo(50.0, 0.1),
      );
      expect(
        WinAccuracyCalculator.winPercentFromScore(cp: 100),
        closeTo(59.1, 0.1),
      );
      expect(
        WinAccuracyCalculator.winPercentFromScore(cp: -100),
        closeTo(40.9, 0.1),
      );
      expect(
        WinAccuracyCalculator.winPercentFromScore(cp: 300),
        closeTo(75.1, 0.1),
      );
      expect(
        WinAccuracyCalculator.winPercentFromScore(cp: 600),
        closeTo(90.1, 0.1),
      );
    });

    test('T-ACC-01: Accuracy from deltaW', () {
      expect(
        WinAccuracyCalculator.moveAccuracyFromDeltaW(0),
        closeTo(100.0, 0.1),
      );
      expect(
        WinAccuracyCalculator.moveAccuracyFromDeltaW(5),
        closeTo(79.8, 0.1),
      );
      expect(
        WinAccuracyCalculator.moveAccuracyFromDeltaW(10),
        closeTo(63.6, 0.1),
      );
      expect(
        WinAccuracyCalculator.moveAccuracyFromDeltaW(20),
        closeTo(40.0, 0.1),
      );
      expect(
        WinAccuracyCalculator.moveAccuracyFromDeltaW(40),
        closeTo(14.9, 0.1),
      );
    });

    test('T-CLS-01..03: Labels under Lichess-style preset & special rules', () {
      // Top move, ΔW 0.5 -> Best
      expect(
        MoveClassifier.classify(
          winBefore: 52.0,
          winAfter: 51.5,
          deltaW: 0.5,
          isBook: false,
          isEngineTopMove: true,
          isSacrifice: false,
          isRecapture: false,
          isForcedOnlyLegalMove: false,
        ),
        MoveClassification.best,
      );

      // ΔW 1.5 -> Excellent
      expect(
        MoveClassifier.classify(
          winBefore: 52.0,
          winAfter: 50.5,
          deltaW: 1.5,
          isBook: false,
          isEngineTopMove: false,
          isSacrifice: false,
          isRecapture: false,
          isForcedOnlyLegalMove: false,
        ),
        MoveClassification.excellent,
      );

      // ΔW 5 -> Good
      expect(
        MoveClassifier.classify(
          winBefore: 55.0,
          winAfter: 50.0,
          deltaW: 5.0,
          isBook: false,
          isEngineTopMove: false,
          isSacrifice: false,
          isRecapture: false,
          isForcedOnlyLegalMove: false,
        ),
        MoveClassification.good,
      );

      // ΔW 12 -> Inaccuracy
      expect(
        MoveClassifier.classify(
          winBefore: 55.0,
          winAfter: 43.0,
          deltaW: 12.0,
          isBook: false,
          isEngineTopMove: false,
          isSacrifice: false,
          isRecapture: false,
          isForcedOnlyLegalMove: false,
        ),
        MoveClassification.inaccuracy,
      );

      // ΔW 25 -> Mistake (when not crossing 60->40 transition)
      expect(
        MoveClassifier.classify(
          winBefore: 70.0,
          winAfter: 45.0,
          deltaW: 25.0,
          isBook: false,
          isEngineTopMove: false,
          isSacrifice: false,
          isRecapture: false,
          isForcedOnlyLegalMove: false,
        ),
        MoveClassification.mistake,
      );

      // ΔW 35 -> Blunder
      expect(
        MoveClassifier.classify(
          winBefore: 70.0,
          winAfter: 35.0,
          deltaW: 35.0,
          isBook: false,
          isEngineTopMove: false,
          isSacrifice: false,
          isRecapture: false,
          isForcedOnlyLegalMove: false,
        ),
        MoveClassification.blunder,
      );

      // Win% 65 to 38 (ΔW 27) -> Blunder (transition rule beats the Mistake band)
      expect(
        MoveClassifier.classify(
          winBefore: 65.0,
          winAfter: 38.0,
          deltaW: 27.0,
          isBook: false,
          isEngineTopMove: false,
          isSacrifice: false,
          isRecapture: false,
          isForcedOnlyLegalMove: false,
        ),
        MoveClassification.blunder,
      );

      // Reply that recaptures, ΔW 0 -> Best, never Brilliant
      expect(
        MoveClassifier.classify(
          winBefore: 55.0,
          winAfter: 55.0,
          deltaW: 0.0,
          isBook: false,
          isEngineTopMove: true,
          isSacrifice: true,
          isRecapture: true,
          isForcedOnlyLegalMove: false,
          secondBestDeltaW: 20.0,
        ),
        MoveClassification.best,
      );

      // Mover already at W 95, sacrifice sound -> Not Brilliant (W > 90 rule)
      expect(
        MoveClassifier.classify(
          winBefore: 95.0,
          winAfter: 94.5,
          deltaW: 0.5,
          isBook: false,
          isEngineTopMove: true,
          isSacrifice: true,
          isRecapture: false,
          isForcedOnlyLegalMove: false,
          secondBestDeltaW: 25.0,
        ),
        MoveClassification.best,
      );
    });

    test('Part 19-3 & 19-8: Phase precedence and volatility window k', () {
      // Endgame (material <= 13) beats Opening (ply <= 24)
      const kingAndRookFen = '4k3/8/8/8/8/8/4R3/4K3 w - - 0 5';
      expect(
        PhaseDetector.detectPhase(fen: kingAndRookFen, ply: 10, isBook: false),
        GamePhase.endgame,
      );

      // Volatility window k = clamp(floor(plies / 10), 2, 8)
      expect(WinAccuracyCalculator.volatilityWindowSize(15), 2);
      expect(WinAccuracyCalculator.volatilityWindowSize(45), 4);
      expect(WinAccuracyCalculator.volatilityWindowSize(120), 8);
    });
  });
}
