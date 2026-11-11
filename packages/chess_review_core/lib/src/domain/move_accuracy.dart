import 'dart:math' as math;

/// Core Move-Accuracy domain primitive.
///
/// SPEC RULES:
/// Accuracy formula:
/// Accuracy = clamp(103.1668100711649 * exp(-0.04354415386753951 * deltaW) - 3.166924740191411 + bonus, 0, 100)
/// where bonus is a configurable parameter (default 1.0).
/// deltaW is clamped to non-negative (>= 0.0) before calculation.
abstract final class MoveAccuracy {
  static const double kCoeffA = 103.1668100711649;
  static const double kCoeffB = -0.04354415386753951;
  static const double kConstantC = 3.166924740191411;

  /// Calculates individual move accuracy in [0.0, 100.0] given win% loss [deltaW].
  ///
  /// Negative [deltaW] (engine search horizon noise) is treated as 0.0 loss.
  static double calculate({
    required double deltaW,
    double bonus = 1.0,
  }) {
    if (deltaW.isNaN) return 0.0;
    final nonNegativeDelta = math.max(0.0, deltaW);
    final raw = kCoeffA * math.exp(kCoeffB * nonNegativeDelta) - kConstantC + bonus;
    if (raw.isNaN) return 0.0;
    return raw.clamp(0.0, 100.0);
  }
}
