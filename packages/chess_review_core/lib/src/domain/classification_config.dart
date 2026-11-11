/// Move classification labels in priority order.
enum ClassificationLabel {
  book,
  brilliant,
  great,
  best,
  excellent,
  good,
  inaccuracy,
  mistake,
  blunder;

  /// Whether this label represents a positive move (Book, Brilliant, Great, Best, Excellent, Good).
  bool get isPositive =>
      this == book ||
      this == brilliant ||
      this == great ||
      this == best ||
      this == excellent ||
      this == good;

  /// Whether this label is a negative error (Inaccuracy, Mistake, Blunder).
  bool get isError =>
      this == inaccuracy || this == mistake || this == blunder;
}

/// Window alignment strategy for volatility-weighted mean aggregate accuracy.
enum WindowAlignment {
  /// Window looks ahead (future moves).
  leading,

  /// Window looks behind (prior moves).
  trailing,

  /// Window is centered around the current ply.
  centred,
}

/// Threshold bands for deltaW move classification.
class ClassificationBands {
  /// Upper bound for Best (when played move is engine top move). Default < 1.0.
  final double bestDeltaMax;

  /// Upper bound for Excellent. Default [1.0, 2.0).
  final double excellentDeltaMax;

  /// Upper bound for Good. Default [2.0, 10.0).
  final double goodDeltaMax;

  /// Upper bound for Inaccuracy. Default [10.0, 20.0).
  final double inaccuracyDeltaMax;

  /// Upper bound for Mistake. Default [20.0, 30.0). Blunder is >= blunderThreshold.
  final double mistakeDeltaMax;

  const ClassificationBands({
    required this.bestDeltaMax,
    required this.excellentDeltaMax,
    required this.goodDeltaMax,
    required this.inaccuracyDeltaMax,
    required this.mistakeDeltaMax,
  });

  /// Lichess-style preset (Default):
  /// Best <1 (top move), Excellent 1-2, Good 2-10, Inaccuracy 10-20, Mistake 20-30, Blunder >=30.
  static const ClassificationBands lichessStyle = ClassificationBands(
    bestDeltaMax: 1.0,
    excellentDeltaMax: 2.0,
    goodDeltaMax: 10.0,
    inaccuracyDeltaMax: 20.0,
    mistakeDeltaMax: 30.0,
  );

  /// Chess.com-style preset:
  /// Best <1, Excellent 1-2, Good 2-5, Inaccuracy 5-10, Mistake 10-20, Blunder >=20.
  static const ClassificationBands chesscomStyle = ClassificationBands(
    bestDeltaMax: 1.0,
    excellentDeltaMax: 2.0,
    goodDeltaMax: 5.0,
    inaccuracyDeltaMax: 10.0,
    mistakeDeltaMax: 20.0,
  );

  /// Wintr-style preset (unverified reference):
  /// Best <1, Excellent 1-4, Good 4-8, Inaccuracy 8-18, Mistake 18-35, Blunder >=35.
  static const ClassificationBands wintrStyle = ClassificationBands(
    bestDeltaMax: 1.0,
    excellentDeltaMax: 4.0,
    goodDeltaMax: 8.0,
    inaccuracyDeltaMax: 18.0,
    mistakeDeltaMax: 35.0,
  );
}

/// Configuration settings for chess move classification and accuracy calculation.
class ClassificationConfig {
  /// DeltaW band thresholds (defaults to Lichess-style).
  final ClassificationBands bands;

  /// Move accuracy formula bonus (default 1.0).
  final double accuracyBonus;

  /// Whether book moves are included when calculating overall accuracy (default true).
  final bool countBookInAccuracy;

  /// Whether the "turns the game" variant for Great moves is enabled (default false).
  final bool turnsTheGameVariant;

  /// Window alignment choice for Lichess-style composite accuracy (default centred).
  final WindowAlignment windowAlignment;

  /// Harmonic mean epsilon to prevent division by zero in aggregate accuracy (default 1e-4).
  final double harmonicEpsilon;

  /// Low win% threshold for the saturation guard (default 5.0).
  final double saturationGuardWinPercent;

  /// Centipawn loss threshold to force at least Mistake when in saturation (default 300).
  final int saturationMistakeCpLoss;

  /// Centipawn loss threshold to force Blunder when in saturation (default 600).
  final int saturationBlunderCpLoss;

  /// Blunder swing guard: W_before threshold (default 60.0).
  final double blunderSwingBeforeThreshold;

  /// Blunder swing guard: W_after threshold (default 40.0).
  /// Dropping from clearly winning (>=60%) into clearly worse (<=40%) always ruins the game outcome.
  final double blunderSwingAfterThreshold;

  /// Brilliant max distance from top move in win% points (default 1.0).
  /// Allows near-top sacrifices ("top move or within 1 point of top") without rewarding unsound gambits.
  final double brilliantTopDeltaMax;

  /// Real SEE threshold in pawn units for a Brilliant sacrifice (default -2).
  /// Captures true material sacrifices (at least an exchange loss, 5 vs 3 = -2, or minor sacrifice).
  final int brilliantSeeThreshold;

  /// Minimum PV plies to trace after a sacrifice to ensure material loss is sustained (default 4).
  /// Prevents temporary 1-2 move deflections (e.g. Bxh7+ Kxh7 Qxd8) from being misclassified as sacrifices.
  final int brilliantSustainedPvPlies;

  /// Minimum W_after for Brilliant (default 35.0).
  /// Avoids labeling losing desperation sacrifices as Brilliant.
  final double brilliantMinWinAfter;

  /// Maximum W_after and W_before for Brilliant/Great (default 90.0).
  /// Avoids diluting Brilliant/Great labels on trivial moves in already won games.
  final double specialMoveMaxWinPercent;

  /// Minimum win% lead over the second-best move required for Great (default 15.0).
  /// Ensures Great identifies genuinely critical, hard-to-find "only moves".
  final double greatSecondBestDeltaMin;

  /// Maximum deltaW distance for an alternative move to block Brilliant (default 1.0).
  /// If a non-sacrificial move exists within 1 point, the sacrifice is optional rather than Brilliant.
  final double brilliantAlternativeDeltaMax;

  /// Minimum opponent drop D (in win%) to evaluate missedPunishment (default 20.0).
  /// Only genuine opponent Mistakes/Blunders create a punishable tactical opportunity.
  final double missMinOpponentDrop;

  /// Minimum fraction of opponent drop D that mover must retain to avoid missedPunishment (default 0.7).
  /// Failing to keep at least 70% of the gifted win probability means the punishment was missed.
  final double missRecoveryRatio;

  /// MultiPV 2 candidate window bounds in W_before when top move is played (default [20.0, 90.0]).
  /// Skips costly MultiPV 2 searches in hopeless (<20%) or trivial (>90%) positions unless deltaW >= 10.
  final double multiPv2MinWinBefore;
  final double multiPv2MaxWinBefore;

  /// MultiPV 2 candidate threshold on deltaW regardless of W_before (default 10.0).
  final double multiPv2DeltaWThreshold;

  const ClassificationConfig({
    this.bands = ClassificationBands.lichessStyle,
    this.accuracyBonus = 1.0,
    this.countBookInAccuracy = true,
    this.turnsTheGameVariant = false,
    this.windowAlignment = WindowAlignment.centred,
    this.harmonicEpsilon = 1e-4,
    this.saturationGuardWinPercent = 5.0,
    this.saturationMistakeCpLoss = 300,
    this.saturationBlunderCpLoss = 600,
    this.blunderSwingBeforeThreshold = 60.0,
    this.blunderSwingAfterThreshold = 40.0,
    this.brilliantTopDeltaMax = 1.0,
    this.brilliantSeeThreshold = -2,
    this.brilliantSustainedPvPlies = 4,
    this.brilliantMinWinAfter = 35.0,
    this.specialMoveMaxWinPercent = 90.0,
    this.greatSecondBestDeltaMin = 15.0,
    this.brilliantAlternativeDeltaMax = 1.0,
    this.missMinOpponentDrop = 20.0,
    this.missRecoveryRatio = 0.7,
    this.multiPv2MinWinBefore = 20.0,
    this.multiPv2MaxWinBefore = 90.0,
    this.multiPv2DeltaWThreshold = 10.0,
  });

  /// Standard default configuration following the authoritative spec.
  static const ClassificationConfig standard = ClassificationConfig();
}
