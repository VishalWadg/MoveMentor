import 'dart:math' as math;
import 'classification_config.dart';
import 'classifier.dart';
import 'game_reviewer.dart';
import 'phase_detector.dart';

/// Aggregated statistics for one player across a reviewed game.
class SideAggregate {
  /// Lichess-style composite accuracy in [0.0, 100.0]:
  /// `(volatilityWeightedAccuracy + harmonicAccuracy) / 2`.
  final double compositeAccuracy;

  /// Volatility-weighted arithmetic mean of move accuracies in [0.0, 100.0].
  final double volatilityWeightedAccuracy;

  /// Stabilized harmonic mean of move accuracies in [0.0, 100.0].
  final double harmonicAccuracy;

  /// Average Centipawn Loss (mates capped at +/-1000).
  final double acpl;

  /// Number of moves included in accuracy / ACPL calculations for this side.
  final int moveCount;

  /// Per-phase composite accuracies (only contains phases with >= 1 counted move).
  final Map<GamePhase, double> phaseAccuracies;

  /// Counts of each classification label across all moves played by this side.
  final Map<ClassificationLabel, int> labelCounts;

  /// Total moves flagged with `missedPunishment == true` for this side.
  final int missedPunishmentCount;

  const SideAggregate({
    required this.compositeAccuracy,
    required this.volatilityWeightedAccuracy,
    required this.harmonicAccuracy,
    required this.acpl,
    required this.moveCount,
    required this.phaseAccuracies,
    required this.labelCounts,
    required this.missedPunishmentCount,
  });

  static const SideAggregate empty = SideAggregate(
    compositeAccuracy: 0.0,
    volatilityWeightedAccuracy: 0.0,
    harmonicAccuracy: 0.0,
    acpl: 0.0,
    moveCount: 0,
    phaseAccuracies: {},
    labelCounts: {},
    missedPunishmentCount: 0,
  );
}

/// Complete per-game accuracy and ACPL aggregates for both sides.
class GameAggregates {
  final SideAggregate white;
  final SideAggregate black;

  /// Target sliding window width `k = clamp(floor(plies / 10), 2, 8)`.
  final int windowSizeK;

  /// Alignment strategy used for sliding volatility windows.
  final WindowAlignment alignment;

  /// Unified White-perspective win% `[0.0, 100.0]` for all `N + 1` board positions.
  final List<double> positionWinPercentsWhite;

  /// Per-move volatility weights clamped to `[0.5, 12.0]` for all `N` plies.
  final List<double> perMoveWeights;

  const GameAggregates({
    required this.white,
    required this.black,
    required this.windowSizeK,
    required this.alignment,
    required this.positionWinPercentsWhite,
    required this.perMoveWeights,
  });
}

/// Pure-Dart aggregator implementing Lichess-style composite accuracy,
/// sliding window volatility weights, harmonic stabilization, and ACPL.
///
/// BOUNDARY BEHAVIOR (consistent across leading, trailing, centred):
/// Let M = N + 1 positions indexed `0..M-1`, and target window k in `[2, 8]`.
/// For move index `t` (`0 <= t < N`, transitioning `S_t -> S_{t+1}`):
/// - `leading`: `[t, t + k)`
/// - `trailing`: `[t + 2 - k, t + 2)`
/// - `centred`: `[t - floor((k - 2) / 2), t - floor((k - 2) / 2) + k)`
/// All bounds are clamped strictly to `[0, M]` without duplicating or padding
/// elements. At game edges where raw clamping yields `< 2` samples (when `M >= 2`),
/// the window expands 1 step into the valid interior so `end - start >= 2` holds
/// everywhere without invalid indexing.
abstract final class Aggregates {
  static const double kMinVolatilityWeight = 0.5;
  static const double kMaxVolatilityWeight = 12.0;
  static const int kMinWindowK = 2;
  static const int kMaxWindowK = 8;

  /// Computes target sliding window size `k = clamp(floor(plies/10), 2, 8)`.
  static int windowSize(int pliesCount) {
    if (pliesCount <= 0) return kMinWindowK;
    return (pliesCount ~/ 10).clamp(kMinWindowK, kMaxWindowK);
  }

  /// Computes clamped `[start, end)` slice bounds within `[0, positionsCount]`
  /// for ply [plyIndex] (`0 <= plyIndex < positionsCount - 1`).
  ///
  /// Guarantees `0 <= start <= end <= positionsCount` and preserves at least
  /// 2 samples whenever `positionsCount >= 2`.
  static ({int start, int end}) computeWindowRange({
    required int plyIndex,
    required int positionsCount,
    required int windowSizeK,
    required WindowAlignment alignment,
  }) {
    if (positionsCount < 2) {
      return (start: 0, end: math.max(0, positionsCount));
    }
    final k = math.min(
      windowSizeK.clamp(kMinWindowK, kMaxWindowK),
      positionsCount,
    );

    final int idealStart;
    final int idealEnd;
    switch (alignment) {
      case WindowAlignment.leading:
        idealStart = plyIndex;
        idealEnd = plyIndex + k;
        break;
      case WindowAlignment.trailing:
        idealEnd = plyIndex + 2;
        idealStart = idealEnd - k;
        break;
      case WindowAlignment.centred:
        final extraBefore = (k - 2) ~/ 2;
        idealStart = plyIndex - extraBefore;
        idealEnd = idealStart + k;
        break;
    }

    var start = idealStart.clamp(0, positionsCount);
    var end = idealEnd.clamp(0, positionsCount);

    // Ensure at least 2 samples when available without exceeding [0, positionsCount].
    if (end - start < 2) {
      if (start == 0) {
        end = math.min(positionsCount, 2);
      } else {
        start = math.max(0, end - 2);
      }
    }
    return (start: start, end: end);
  }

  /// Computes population standard deviation over `values.sublist(start, end)`.
  static double windowStdDev(List<double> values, int start, int end) {
    final len = end - start;
    if (len < 2 || start < 0 || end > values.length) return 0.0;

    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += values[i];
    }
    final mean = sum / len;

    var sqSum = 0.0;
    for (var i = start; i < end; i++) {
      final diff = values[i] - mean;
      sqSum += diff * diff;
    }
    return math.sqrt(sqSum / len);
  }

  /// Computes full White and Black accuracy/ACPL aggregates for a reviewed game.
  static GameAggregates compute(
    GameReviewResult review, {
    ClassificationConfig config = ClassificationConfig.standard,
    bool? initialTurnIsWhite,
  }) {
    final plies = review.plies;
    final k = windowSize(plies.length);

    if (plies.isEmpty) {
      return GameAggregates(
        white: SideAggregate.empty,
        black: SideAggregate.empty,
        windowSizeK: k,
        alignment: config.windowAlignment,
        positionWinPercentsWhite: const [],
        perMoveWeights: const [],
      );
    }

    final startsWhite = initialTurnIsWhite ?? _isWhiteTurnFen(review.initialFen);
    bool isWhitePly(int index) => startsWhite ? index.isEven : index.isOdd;

    // Build unified White-perspective win% array of length N + 1.
    final positionsWhite = List<double>.filled(plies.length + 1, 50.0);
    positionsWhite[0] = (isWhitePly(0)
            ? plies[0].winBefore
            : 100.0 - plies[0].winBefore)
        .clamp(0.0, 100.0);
    for (var i = 0; i < plies.length; i++) {
      final wAfterWhite =
          isWhitePly(i) ? plies[i].winAfter : 100.0 - plies[i].winAfter;
      positionsWhite[i + 1] = wAfterWhite.clamp(0.0, 100.0);
    }

    // Compute per-move volatility weights clamped to [0.5, 12.0].
    final weights = List<double>.filled(plies.length, kMinVolatilityWeight);
    for (var t = 0; t < plies.length; t++) {
      final range = computeWindowRange(
        plyIndex: t,
        positionsCount: positionsWhite.length,
        windowSizeK: k,
        alignment: config.windowAlignment,
      );
      final stdDev = windowStdDev(positionsWhite, range.start, range.end);
      weights[t] = stdDev.clamp(kMinVolatilityWeight, kMaxVolatilityWeight);
    }

    final whiteIndices = <int>[];
    final blackIndices = <int>[];
    for (var i = 0; i < plies.length; i++) {
      if (isWhitePly(i)) {
        whiteIndices.add(i);
      } else {
        blackIndices.add(i);
      }
    }

    return GameAggregates(
      white: _aggregateSide(plies, weights, whiteIndices, config),
      black: _aggregateSide(plies, weights, blackIndices, config),
      windowSizeK: k,
      alignment: config.windowAlignment,
      positionWinPercentsWhite: positionsWhite,
      perMoveWeights: weights,
    );
  }

  static SideAggregate _aggregateSide(
    List<MoveClassificationResult> plies,
    List<double> weights,
    List<int> indices,
    ClassificationConfig config,
  ) {
    if (indices.isEmpty) return SideAggregate.empty;

    final labelCounts = <ClassificationLabel, int>{};
    var missedCount = 0;
    final countedIndices = <int>[];

    for (final idx in indices) {
      final res = plies[idx];
      labelCounts[res.label] = (labelCounts[res.label] ?? 0) + 1;
      if (res.missedPunishment) {
        missedCount++;
      }
      if (config.countBookInAccuracy || !res.isBook) {
        countedIndices.add(idx);
      }
    }

    if (countedIndices.isEmpty) {
      return SideAggregate(
        compositeAccuracy: 0.0,
        volatilityWeightedAccuracy: 0.0,
        harmonicAccuracy: 0.0,
        acpl: 0.0,
        moveCount: 0,
        phaseAccuracies: const {},
        labelCounts: labelCounts,
        missedPunishmentCount: missedCount,
      );
    }

    final stats = _computeAccuracyStats(
      countedIndices.map((i) => plies[i]).toList(),
      countedIndices.map((i) => weights[i]).toList(),
      config.harmonicEpsilon,
    );

    final phaseAccuracies = <GamePhase, double>{};
    for (final phase in GamePhase.values) {
      final phaseIndices = countedIndices
          .where((i) => plies[i].phase == phase)
          .toList();
      if (phaseIndices.isNotEmpty) {
        final phaseStats = _computeAccuracyStats(
          phaseIndices.map((i) => plies[i]).toList(),
          phaseIndices.map((i) => weights[i]).toList(),
          config.harmonicEpsilon,
        );
        phaseAccuracies[phase] = phaseStats.composite;
      }
    }

    return SideAggregate(
      compositeAccuracy: stats.composite,
      volatilityWeightedAccuracy: stats.weightedMean,
      harmonicAccuracy: stats.harmonicMean,
      acpl: stats.acpl,
      moveCount: countedIndices.length,
      phaseAccuracies: phaseAccuracies,
      labelCounts: labelCounts,
      missedPunishmentCount: missedCount,
    );
  }

  static ({
    double composite,
    double weightedMean,
    double harmonicMean,
    double acpl,
  }) _computeAccuracyStats(
    List<MoveClassificationResult> moves,
    List<double> moveWeights,
    double harmonicEpsilon,
  ) {
    final n = moves.length;
    if (n == 0) {
      return (composite: 0.0, weightedMean: 0.0, harmonicMean: 0.0, acpl: 0.0);
    }

    var weightedAccSum = 0.0;
    var weightSum = 0.0;
    var reciprocalSum = 0.0;
    var cpLossSum = 0;

    for (var i = 0; i < n; i++) {
      final acc = moves[i].accuracy.clamp(0.0, 100.0);
      final w = moveWeights[i];
      weightedAccSum += acc * w;
      weightSum += w;
      reciprocalSum += 1.0 / math.max(acc, harmonicEpsilon);
      cpLossSum += math.max(0, moves[i].cpLoss);
    }

    final weightedMean =
        (weightSum > 0.0 ? weightedAccSum / weightSum : 0.0).clamp(0.0, 100.0);
    final harmonicMean = (n / reciprocalSum).clamp(0.0, 100.0);
    final composite = ((weightedMean + harmonicMean) / 2.0).clamp(0.0, 100.0);
    final acpl = cpLossSum / n;

    return (
      composite: composite,
      weightedMean: weightedMean,
      harmonicMean: harmonicMean,
      acpl: acpl,
    );
  }

  static bool _isWhiteTurnFen(String fen) {
    final parts = fen.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return parts[1].toLowerCase() != 'b';
    }
    return true;
  }
}
