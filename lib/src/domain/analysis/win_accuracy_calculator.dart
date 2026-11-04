import 'dart:math' as math;

/// Part 11.3, 11.4, 19-8 & 30.2: Deterministic Win%, Move Accuracy, Volatility-Weighted
/// and Harmonic Mean Composite Game Accuracy, and ACPL.
class WinAccuracyCalculator {
  /// Part 11.3: `W(cp) = 50 + 50 * (2 / (1 + exp(-0.00368208 * cp)) - 1)`
  /// Mate scores map to 100.0 (mate for mover) or 0.0 (mate against mover).
  static double winPercentFromScore({int? cp, int? mate}) {
    if (mate != null && mate != 0) {
      return mate > 0 ? 100.0 : 0.0;
    }
    final clampedCp = (cp ?? 0).clamp(-1000, 1000).toDouble();
    final w = 50.0 + 50.0 * (2.0 / (1.0 + math.exp(-0.00368208 * clampedCp)) - 1.0);
    return w.clamp(0.0, 100.0);
  }

  /// Part 11.3: `ΔW = W_before(mover) - W_after(mover)` (clamped at 0 when move improves).
  static double computeDeltaW(double winBeforeMover, double winAfterMover) {
    final drop = winBeforeMover - winAfterMover;
    return drop > 0.0 ? drop : 0.0;
  }

  /// Part 11.4: `Accuracy = clamp(103.1668 * exp(-0.04354 * ΔW) - 3.1669, 0, 100)`
  /// Reproduces golden vectors (Part 30.2): ΔW 0->100.0, 5->79.8, 10->63.6, 20->40.0, 40->14.9.
  static double moveAccuracyFromDeltaW(double deltaW) {
    if (deltaW <= 0.0) return 100.0;
    final raw = 103.1668 * math.exp(-0.04354 * deltaW) - 3.1669;
    return raw.clamp(0.0, 100.0);
  }

  /// Part 19-8: Volatility window size `k = clamp(floor(plies / 10), 2, 8)`.
  static int volatilityWindowSize(int totalPlies) {
    if (totalPlies <= 0) return 2;
    return (totalPlies ~/ 10).clamp(2, 8);
  }

  /// Computes per-ply volatility weight `v = clamp(σ, 0.5, 12.0)` over sliding window of `k` half-moves.
  static List<double> computeVolatilities(List<double> whiteWinPercents) {
    final totalPlies = whiteWinPercents.length;
    if (totalPlies == 0) return const [];
    final k = volatilityWindowSize(totalPlies);
    final result = <double>[];

    for (var i = 0; i < totalPlies; i++) {
      final start = math.max(0, i - k + 1);
      final end = math.min(totalPlies, start + k);
      final window = whiteWinPercents.sublist(start, end);
      if (window.length < 2) {
        result.add(0.5);
        continue;
      }
      final mean = window.reduce((a, b) => a + b) / window.length;
      final variance = window
              .map((w) => (w - mean) * (w - mean))
              .reduce((a, b) => a + b) /
          window.length;
      final sigma = math.sqrt(variance);
      result.add(sigma.clamp(0.5, 12.0));
    }
    return result;
  }

  /// Part 11.4: Composite Game Accuracy = `(A_V + A_H) / 2`.
  static double computeCompositeAccuracy({
    required List<double> moveAccuracies,
    required List<double> volatilities,
  }) {
    if (moveAccuracies.isEmpty) return 100.0;
    final n = moveAccuracies.length;
    var weightedSum = 0.0;
    var weightTotal = 0.0;
    var harmonicDenom = 0.0;

    for (var i = 0; i < n; i++) {
      final acc = moveAccuracies[i].clamp(0.0, 100.0);
      final v = i < volatilities.length ? volatilities[i].clamp(0.5, 12.0) : 1.0;
      weightedSum += v * acc;
      weightTotal += v;
      harmonicDenom += 1.0 / (acc + 0.0001);
    }

    final aV = weightTotal > 0 ? (weightedSum / weightTotal) : 100.0;
    final aH = harmonicDenom > 0 ? (n / harmonicDenom) : 100.0;
    return ((aV + aH) / 2.0).clamp(0.0, 100.0);
  }

  /// Part 11.9: Average Centipawn Loss (ACPL) with mate capped at ±1000.
  static double computeAcpl(List<double> cpLosses) {
    if (cpLosses.isEmpty) return 0.0;
    final total = cpLosses.reduce((a, b) => a + b);
    return total / cpLosses.length;
  }
}
