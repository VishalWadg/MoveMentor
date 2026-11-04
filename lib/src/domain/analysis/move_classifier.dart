import '../chess/chess_models.dart';

/// Part 11.5: Configurable classification thresholds with two presets:
/// - `lichess` (default: inaccuracy 10, mistake 20, blunder 30)
/// - `pdf` (source PDF bands: inaccuracy 5, mistake 10, blunder 20)
class ClassificationConfig {
  final String presetId;
  final int maxBookPly;
  final double bestMaxDeltaW;
  final double excellentMaxDeltaW;
  final double inaccuracyThreshold;
  final double mistakeThreshold;
  final double blunderThreshold;
  final double greatSecondBestGap;
  final double transitionWinHigh;
  final double transitionWinLow;

  const ClassificationConfig({
    required this.presetId,
    this.maxBookPly = 20,
    this.bestMaxDeltaW = 1.0,
    this.excellentMaxDeltaW = 2.0,
    required this.inaccuracyThreshold,
    required this.mistakeThreshold,
    required this.blunderThreshold,
    this.greatSecondBestGap = 15.0,
    this.transitionWinHigh = 60.0,
    this.transitionWinLow = 40.0,
  });

  static const ClassificationConfig lichessPreset = ClassificationConfig(
    presetId: 'lichess',
    inaccuracyThreshold: 10.0,
    mistakeThreshold: 20.0,
    blunderThreshold: 30.0,
  );

  static const ClassificationConfig pdfPreset = ClassificationConfig(
    presetId: 'pdf',
    inaccuracyThreshold: 5.0,
    mistakeThreshold: 10.0,
    blunderThreshold: 20.0,
  );

  static ClassificationConfig byId(String? id) =>
      id == 'pdf' ? pdfPreset : lichessPreset;
}

/// Part 11.5, 19-4, 19-6 & 30.2: Evaluates move classification top-to-bottom.
class MoveClassifier {
  static MoveClassification classify({
    required double winBefore,
    required double winAfter,
    required double deltaW,
    required bool isBook,
    required bool isEngineTopMove,
    required bool isSacrifice,
    required bool isRecapture,
    required bool isForcedOnlyLegalMove,
    double? secondBestDeltaW,
    int? mateBeforeForMover,
    int? mateAfterForMover,
    ClassificationConfig config = ClassificationConfig.lichessPreset,
  }) {
    // 1. Book
    if (isBook) {
      return MoveClassification.book;
    }

    // Check Part 19-4 "Allowing mate": after the move the engine reports a forced mate
    // against the mover (mateAfterForMover < 0), and before the move it did not.
    final allowedMate = (mateAfterForMover != null && mateAfterForMover < 0) &&
        (mateBeforeForMover == null || mateBeforeForMover >= 0);

    // Check Transition Rule (Part 11.5 Order 9 & Part 30.2 Golden Vector: Win% 65 to 38 -> Blunder)
    final collapsedFromWinningToLost =
        winBefore >= config.transitionWinHigh &&
            winAfter <= config.transitionWinLow;

    if (allowedMate ||
        collapsedFromWinningToLost ||
        deltaW >= config.blunderThreshold) {
      return MoveClassification.blunder;
    }

    // Noise prevention rule (Part 11.5 & 30.2): No Brilliant/Great when already winning by a large margin (W > 90)
    final eligibleForSpecial = winBefore <= 90.0;

    // 2. Brilliant
    if (eligibleForSpecial &&
        (isEngineTopMove || deltaW <= config.bestMaxDeltaW) &&
        isSacrifice &&
        !isRecapture &&
        !isForcedOnlyLegalMove &&
        winAfter >= 35.0 &&
        winAfter <= 90.0 &&
        (secondBestDeltaW == null || secondBestDeltaW >= 1.0)) {
      return MoveClassification.brilliant;
    }

    // 3. Great
    final turnsOrSavesGame =
        (winBefore < 45.0 && winAfter >= 50.0) ||
        (winBefore < 55.0 && winAfter >= 68.0);
    final isOnlyGoodMove = secondBestDeltaW != null &&
        secondBestDeltaW >= config.greatSecondBestGap;
    if (eligibleForSpecial &&
        (isEngineTopMove || deltaW <= config.bestMaxDeltaW) &&
        !isSacrifice &&
        !isRecapture &&
        (isOnlyGoodMove || turnsOrSavesGame)) {
      return MoveClassification.great;
    }

    // 4. Best
    if (isEngineTopMove && deltaW < config.bestMaxDeltaW) {
      return MoveClassification.best;
    }
    if (deltaW < config.bestMaxDeltaW) {
      return MoveClassification.best;
    }

    // 5. Excellent
    if (deltaW < config.excellentMaxDeltaW) {
      return MoveClassification.excellent;
    }

    // 6. Good
    if (deltaW < config.inaccuracyThreshold) {
      return MoveClassification.good;
    }

    // 7. Inaccuracy
    if (deltaW < config.mistakeThreshold) {
      return MoveClassification.inaccuracy;
    }

    // 8. Mistake
    return MoveClassification.mistake;
  }

  /// Part 19-6: Determines whether a position is a MultiPV=2 candidate for Fast/Balanced pass 2.
  static bool isMultiPv2Candidate({
    required bool isEngineTopMove,
    required double winBefore,
    required double deltaW,
  }) {
    if (isEngineTopMove && winBefore >= 20.0 && winBefore <= 90.0) {
      return true;
    }
    if (deltaW >= 10.0) {
      return true;
    }
    return false;
  }
}
