import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:chess_review_core/chess_review_core.dart';

MoveClassificationResult _plyResult({
  required String uci,
  required double winBefore,
  required double winAfter,
  int cpLoss = 0,
  ClassificationLabel label = ClassificationLabel.best,
  GamePhase phase = GamePhase.middlegame,
  bool isBook = false,
  bool isForced = false,
  bool missedPunishment = false,
}) {
  final deltaW = math.max(0.0, winBefore - winAfter);
  final acc = MoveAccuracy.calculate(deltaW: deltaW, bonus: 1.0);
  return MoveClassificationResult(
    playedMoveUci: uci,
    label: label,
    winBefore: winBefore,
    winAfter: winAfter,
    deltaW: deltaW,
    accuracy: acc,
    cpLoss: cpLoss,
    phase: phase,
    isBook: isBook,
    isForced: isForced,
    missedPunishment: missedPunishment,
  );
}

void main() {
  group('Aggregates: Window size and boundary clamping (leading, trailing, centred)', () {
    test('windowSize k = clamp(floor(plies/10), 2, 8)', () {
      expect(Aggregates.windowSize(0), equals(2));
      expect(Aggregates.windowSize(1), equals(2));
      expect(Aggregates.windowSize(19), equals(2));
      expect(Aggregates.windowSize(30), equals(3)); // odd
      expect(Aggregates.windowSize(39), equals(3)); // odd
      expect(Aggregates.windowSize(40), equals(4)); // even
      expect(Aggregates.windowSize(55), equals(5)); // odd
      expect(Aggregates.windowSize(60), equals(6)); // even
      expect(Aggregates.windowSize(75), equals(7)); // odd
      expect(Aggregates.windowSize(80), equals(8)); // even
      expect(Aggregates.windowSize(140), equals(8));
    });

    test('boundary clamping for even (k=4) and odd (k=3, k=5) across all 3 alignments', () {
      for (final pliesCount in [1, 2, 10, 30, 40, 50]) {
        final positionsLen = pliesCount + 1;
        final k = (pliesCount >= 30 && pliesCount < 40)
            ? 3
            : (pliesCount >= 50)
                ? 5
                : Aggregates.windowSize(pliesCount);

        for (final alignment in WindowAlignment.values) {
          for (var t = 0; t < pliesCount; t++) {
            final range = Aggregates.computeWindowRange(
              plyIndex: t,
              positionsCount: positionsLen,
              windowSizeK: k,
              alignment: alignment,
            );
            expect(range.start, greaterThanOrEqualTo(0),
                reason: 'start < 0 for N=$pliesCount k=$k $alignment t=$t');
            expect(range.end, lessThanOrEqualTo(positionsLen),
                reason: 'end > M for N=$pliesCount k=$k $alignment t=$t');
            expect(range.end - range.start, greaterThanOrEqualTo(2),
                reason: 'fewer than 2 samples for N=$pliesCount k=$k $alignment t=$t');
            expect(range.end - range.start, lessThanOrEqualTo(k),
                reason: 'window larger than k for N=$pliesCount k=$k $alignment t=$t');
          }
        }
      }
    });

    test('exact interior and boundary slices for even k=4 and odd k=3 (M=11 positions)', () {
      const m = 11; // 10 plies: t = 0..9

      // Even k = 4:
      // Trailing ending at t+1 (end = t+2)
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 0, positionsCount: m, windowSizeK: 4, alignment: WindowAlignment.trailing,
        ),
        equals((start: 0, end: 2)),
      );
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 9, positionsCount: m, windowSizeK: 4, alignment: WindowAlignment.trailing,
        ),
        equals((start: 7, end: 11)),
      );

      // Leading starting at t
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 0, positionsCount: m, windowSizeK: 4, alignment: WindowAlignment.leading,
        ),
        equals((start: 0, end: 4)),
      );
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 9, positionsCount: m, windowSizeK: 4, alignment: WindowAlignment.leading,
        ),
        equals((start: 9, end: 11)),
      );

      // Centred around transition (t, t+1): extraBefore = (4-2)~/2 = 1 -> [t-1, t+3)
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 0, positionsCount: m, windowSizeK: 4, alignment: WindowAlignment.centred,
        ),
        equals((start: 0, end: 3)),
      );
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 5, positionsCount: m, windowSizeK: 4, alignment: WindowAlignment.centred,
        ),
        equals((start: 4, end: 8)),
      );
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 9, positionsCount: m, windowSizeK: 4, alignment: WindowAlignment.centred,
        ),
        equals((start: 8, end: 11)),
      );

      // Odd k = 3:
      // Centred around (t, t+1): extraBefore = (3-2)~/2 = 0 -> [t, t+3)
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 0, positionsCount: m, windowSizeK: 3, alignment: WindowAlignment.centred,
        ),
        equals((start: 0, end: 3)),
      );
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 5, positionsCount: m, windowSizeK: 3, alignment: WindowAlignment.centred,
        ),
        equals((start: 5, end: 8)),
      );
      expect(
        Aggregates.computeWindowRange(
          plyIndex: 9, positionsCount: m, windowSizeK: 3, alignment: WindowAlignment.centred,
        ),
        equals((start: 9, end: 11)),
      );
    });
  });

  group('Aggregates: Perspective, weights, composite accuracy, harmonic epsilon', () {
    test('flat game (52.7% White / 47.3% Black) yields constant White sequence and min weight 0.5', () {
      // If Black moves were NOT flipped back to White perspective, 52.7 / 47.3 would oscillate!
      final review = GameReviewResult(
        initialFen: GameReviewer.kStandardStartFen,
        engineVersion: 'TestSF',
        plies: [
          _plyResult(uci: 'e2e4', winBefore: 52.7, winAfter: 52.7), // White: 52.7 -> 52.7
          _plyResult(uci: 'e7e5', winBefore: 47.3, winAfter: 47.3), // Black: 47.3 -> 47.3 (White 52.7)
          _plyResult(uci: 'g1f3', winBefore: 52.7, winAfter: 52.7), // White: 52.7 -> 52.7
          _plyResult(uci: 'b8c6', winBefore: 47.3, winAfter: 47.3), // Black: 47.3 -> 47.3 (White 52.7)
        ],
      );

      final agg = Aggregates.compute(review);
      for (final wp in agg.positionWinPercentsWhite) {
        expect(wp, closeTo(52.7, 1e-6));
      }
      for (final w in agg.perMoveWeights) {
        expect(w, equals(0.5)); // stdDev = 0.0 -> clamped to 0.5
      }
      expect(agg.white.compositeAccuracy, equals(100.0));
      expect(agg.black.compositeAccuracy, equals(100.0));
    });

    test('high volatility swing clamps weight at 12.0', () {
      // Wild swing: 10% -> 90% -> 10% -> std dev ~ 40 -> clamped to 12.0
      final review = GameReviewResult(
        initialFen: GameReviewer.kStandardStartFen,
        engineVersion: 'TestSF',
        plies: [
          _plyResult(uci: 'e2e4', winBefore: 10.0, winAfter: 10.0),
          _plyResult(uci: 'e7e5', winBefore: 90.0, winAfter: 10.0, label: ClassificationLabel.blunder), // Black blunder gives White 90%
          _plyResult(uci: 'g1f3', winBefore: 90.0, winAfter: 10.0, label: ClassificationLabel.blunder), // White blunders back to 10%
        ],
      );

      final agg = Aggregates.compute(review);
      expect(agg.perMoveWeights.any((w) => w == 12.0), isTrue);
    });

    test('harmonic mean uses epsilon 1e-4 when an accuracy hits 0.0 (no NaN or Infinity)', () {
      final review = GameReviewResult(
        initialFen: GameReviewer.kStandardStartFen,
        engineVersion: 'TestSF',
        plies: [
          _plyResult(uci: 'e2e4', winBefore: 50.0, winAfter: 50.0), // acc = 100
          _plyResult(uci: 'e7e5', winBefore: 50.0, winAfter: 50.0), // Black acc = 100
          _plyResult(uci: 'd1h5', winBefore: 100.0, winAfter: 0.0, label: ClassificationLabel.blunder), // deltaW = 100 -> acc = 0.0!
        ],
      );

      final agg = Aggregates.compute(review);
      expect(agg.white.harmonicAccuracy.isNaN, isFalse);
      expect(agg.white.harmonicAccuracy.isInfinite, isFalse);
      // With eps=1e-4 and n=2 (100 and 0->1e-4): 2 / (0.01 + 10000) ~ 0.0001999998
      expect(agg.white.harmonicAccuracy, closeTo(0.0002, 1e-4));
      expect(
        agg.white.compositeAccuracy,
        closeTo((agg.white.volatilityWeightedAccuracy + agg.white.harmonicAccuracy) / 2.0, 1e-9),
      );
    });
  });

  group('Aggregates: ACPL calculation from mover perspective (White & Black) with mate capped +/-1000', () {
    test('Classifier.classifyMove calculates mover cpLoss symmetrically for White & Black moves', () {
      const classifier = Classifier();

      // White move: cpBefore = +100, opponent after = +250 -> moverAfter = -250 -> cpLoss = 350
      final whiteRes = classifier.classifyMove(
        playedMoveUci: 'd2d4',
        moverScoreBefore: const PositionScore(cp: 100, bestMoveUci: 'e2e4'),
        opponentScoreAfter: const PositionScore(cp: 250, bestMoveUci: 'c7c5'),
      );
      expect(whiteRes.cpLoss, equals(350));

      // Black move (Black had +150 advantage from Black's view, blunders to White +400):
      // moverBefore = +150, oppAfter = +400 -> moverAfter = -400 -> cpLoss = 550
      final blackRes = classifier.classifyMove(
        playedMoveUci: 'g7g5',
        moverScoreBefore: const PositionScore(cp: 150, bestMoveUci: 'e7e5'),
        opponentScoreAfter: const PositionScore(cp: 400, bestMoveUci: 'd1h5'),
      );
      expect(blackRes.cpLoss, equals(550));

      // Mate capping at +-1000:
      // Mover was +300 (0.3s? +300cp), blunders into opponent Mate in 2 (+2 for opp -> -1000 for mover)
      // cpLoss = 300 - (-1000) = 1300
      final blunderToMate = classifier.classifyMove(
        playedMoveUci: 'g7f6',
        moverScoreBefore: const PositionScore(cp: 300, bestMoveUci: 'g7g6'),
        opponentScoreAfter: const PositionScore(mate: 2, bestMoveUci: 'f3f6'),
      );
      expect(blunderToMate.cpLoss, equals(1300));

      // Mate improvement: mover had mate in 3 (+1000) and moves to mate in 2 (+1000 for mover) -> cpLoss = 0
      final mateToMate = classifier.classifyMove(
        playedMoveUci: 'f3f6',
        moverScoreBefore: const PositionScore(mate: 3, bestMoveUci: 'f3f6'),
        opponentScoreAfter: const PositionScore(mate: -2, bestMoveUci: 'f8e8'),
      );
      expect(mateToMate.cpLoss, equals(0));

      // Score above +1000 cp is capped at +1000 (1500 -> 1000, opp -1200 -> mover +1000 -> cpLoss = 0)
      final cappedOverflow = classifier.classifyMove(
        playedMoveUci: 'a2a3',
        moverScoreBefore: const PositionScore(cp: 1500, bestMoveUci: 'd1d8'),
        opponentScoreAfter: const PositionScore(cp: -1200, bestMoveUci: 'e8d7'),
      );
      expect(cappedOverflow.cpLoss, equals(0));
    });

    test('per-side ACPL averages cpLoss accurately for White and Black', () {
      final review = GameReviewResult(
        initialFen: GameReviewer.kStandardStartFen,
        engineVersion: 'TestSF',
        plies: [
          _plyResult(uci: 'e2e4', winBefore: 52, winAfter: 50, cpLoss: 20), // White: 20
          _plyResult(uci: 'e7e5', winBefore: 50, winAfter: 40, cpLoss: 100), // Black: 100
          _plyResult(uci: 'g1f3', winBefore: 60, winAfter: 56, cpLoss: 40), // White: 40
          _plyResult(uci: 'b8c6', winBefore: 44, winAfter: 44, cpLoss: 0), // Black: 0
        ],
      );

      final agg = Aggregates.compute(review);
      expect(agg.white.acpl, closeTo(30.0, 1e-6)); // (20+40)/2
      expect(agg.black.acpl, closeTo(50.0, 1e-6)); // (100+0)/2
    });
  });

  group('Aggregates: Empty games, 1-ply games, Black-first FEN, countBookInAccuracy, phases & counts', () {
    test('empty game handles safely without NaN or errors', () {
      const review = GameReviewResult(
        initialFen: GameReviewer.kStandardStartFen,
        engineVersion: 'TestSF',
        plies: [],
      );
      final agg = Aggregates.compute(review);
      expect(agg.positionWinPercentsWhite, isEmpty);
      expect(agg.perMoveWeights, isEmpty);
      expect(agg.white.moveCount, equals(0));
      expect(agg.black.moveCount, equals(0));
      expect(agg.white.compositeAccuracy, equals(0.0));
      expect(agg.black.compositeAccuracy, equals(0.0));
      expect(agg.white.acpl, equals(0.0));
      expect(agg.white.phaseAccuracies, isEmpty);
    });

    test('one-ply game handles White move cleanly and Black empty side safely', () {
      final review = GameReviewResult(
        initialFen: GameReviewer.kStandardStartFen,
        engineVersion: 'TestSF',
        plies: [
          _plyResult(
            uci: 'e2e4',
            winBefore: 52.0,
            winAfter: 52.0,
            cpLoss: 0,
            label: ClassificationLabel.book,
            phase: GamePhase.opening,
            isBook: true,
          ),
        ],
      );

      for (final alignment in WindowAlignment.values) {
        final agg = Aggregates.compute(
          review,
          config: ClassificationConfig(windowAlignment: alignment),
        );
        expect(agg.positionWinPercentsWhite.length, equals(2));
        expect(agg.white.moveCount, equals(1));
        expect(agg.white.compositeAccuracy, equals(100.0));
        expect(agg.white.phaseAccuracies[GamePhase.opening], equals(100.0));
        expect(agg.white.phaseAccuracies[GamePhase.middlegame], isNull);
        expect(agg.black.moveCount, equals(0));
        expect(agg.black.compositeAccuracy, equals(0.0));
      }
    });

    test('respects custom Black-to-move initial FEN', () {
      const blackToMoveFen = '4k3/8/8/8/8/8/4P3/4K3 b - - 0 1';
      final review = GameReviewResult(
        initialFen: blackToMoveFen,
        engineVersion: 'TestSF',
        plies: [
          _plyResult(uci: 'e8d7', winBefore: 20.0, winAfter: 10.0, cpLoss: 120, label: ClassificationLabel.inaccuracy),
        ],
      );

      final agg = Aggregates.compute(review);
      expect(agg.black.moveCount, equals(1));
      expect(agg.black.acpl, equals(120.0));
      expect(agg.white.moveCount, equals(0));
      // Black had 20% -> 10%, so White perspective is 80% -> 90%
      expect(agg.positionWinPercentsWhite[0], closeTo(80.0, 1e-6));
      expect(agg.positionWinPercentsWhite[1], closeTo(90.0, 1e-6));
    });

    test('countBookInAccuracy false excludes book moves from accuracy and ACPL while preserving windows', () {
      final review = GameReviewResult(
        initialFen: GameReviewer.kStandardStartFen,
        engineVersion: 'TestSF',
        plies: [
          _plyResult(
            uci: 'e2e4',
            winBefore: 52.0,
            winAfter: 40.0, // inaccurate book gambit!
            cpLoss: 100,
            label: ClassificationLabel.book,
            phase: GamePhase.opening,
            isBook: true,
          ),
          _plyResult(uci: 'e7e5', winBefore: 60.0, winAfter: 60.0, isBook: false),
          _plyResult(
            uci: 'g1f3',
            winBefore: 40.0,
            winAfter: 40.0, // accurate non-book move -> 100%
            cpLoss: 0,
            label: ClassificationLabel.best,
            phase: GamePhase.opening,
            isBook: false,
          ),
        ],
      );

      final withBook = Aggregates.compute(
        review,
        config: const ClassificationConfig(countBookInAccuracy: true),
      );
      final withoutBook = Aggregates.compute(
        review,
        config: const ClassificationConfig(countBookInAccuracy: false),
      );

      expect(withBook.white.moveCount, equals(2));
      expect(withBook.white.compositeAccuracy, lessThan(95.0));
      expect(withBook.white.acpl, equals(50.0));

      expect(withoutBook.white.moveCount, equals(1));
      expect(withoutBook.white.compositeAccuracy, equals(100.0));
      expect(withoutBook.white.acpl, equals(0.0));
      // Position window still covers all 4 board positions!
      expect(withoutBook.positionWinPercentsWhite.length, equals(4));
      expect(withoutBook.perMoveWeights.length, equals(3));
    });
  });
}
