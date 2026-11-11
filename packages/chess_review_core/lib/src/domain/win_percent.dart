import 'dart:math' as math;

/// Core Win-Percentage domain primitive.
///
/// SPEC RULES:
/// 1. Units: Win% is 0-100 everywhere. Never mix with 0-1.
/// 2. Evaluation formula:
///    W(cp) = 50 + 50 * (2 / (1 + exp(-0.00368208 * cp)) - 1)
///    where cp is clamped to [-1000, +1000].
/// 3. Mate evaluations:
///    100.0 if the mover is delivering mate (mate > 0).
///    0.0 if the mover is being mated (mate < 0).
///    Mate evaluations explicitly branch; they are NEVER converted to arbitrary cp.
abstract final class WinPercent {
  /// The Lichess logistic winning probability coefficient.
  static const double kWinningProbabilityFactor = -0.00368208;

  /// Maximum centipawn evaluation magnitude considered before saturation.
  static const int kMaxCp = 1000;

  /// Calculates win percentage from mover-perspective centipawn score.
  ///
  /// Centipawns are clamped to [-1000, 1000].
  /// Result is strictly in [0.0, 100.0].
  static double fromCp(int cp) {
    final clampedCp = cp.clamp(-kMaxCp, kMaxCp);
    // W(cp) = 50 + 50 * (2 / (1 + exp(-0.00368208 * cp)) - 1)
    final exponent = kWinningProbabilityFactor * clampedCp;
    final logistic = 2.0 / (1.0 + math.exp(exponent)) - 1.0;
    return (50.0 + 50.0 * logistic).clamp(0.0, 100.0);
  }

  /// Calculates win percentage from mover-perspective mate distance.
  ///
  /// Positive mate (> 0) means the mover is delivering checkmate -> 100.0.
  /// Negative mate (< 0) means the mover is being checkmated -> 0.0.
  static double fromMate(int mate) {
    if (mate > 0) return 100.0;
    if (mate < 0) return 0.0;
    // Mate 0 represents terminal checkmate on the board.
    return 100.0;
  }

  /// Calculates win percentage from an engine evaluation (either cp or mate)
  /// given from the side-to-move's perspective.
  static double fromScore({int? cp, int? mate}) {
    if (mate != null) {
      return fromMate(mate);
    }
    if (cp != null) {
      return fromCp(cp);
    }
    // Default neutral evaluation if neither is provided.
    return 50.0;
  }
}
