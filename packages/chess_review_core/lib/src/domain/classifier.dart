import 'dart:math' as math;
import 'classification_config.dart';
import 'move_accuracy.dart';
import 'phase_detector.dart';
import 'win_percent.dart';
import '../ports/engine_service.dart';

/// Score of a position from the perspective of the side to move.
class PositionScore {
  /// Evaluation in centipawns (from side-to-move's perspective).
  final int? cp;

  /// Evaluation in mate distance (positive if mover mates, negative if mover is mated).
  final int? mate;

  /// Best move in UCI notation (from multiPV line 1).
  final String? bestMoveUci;

  /// Full PV moves in UCI notation.
  final List<String> pv;

  const PositionScore({
    this.cp,
    this.mate,
    this.bestMoveUci,
    this.pv = const [],
  });

  /// Effective top move UCI (from bestMoveUci or first PV move).
  String? get topMoveUci => bestMoveUci ?? (pv.isNotEmpty ? pv.first : null);

  /// Whether the engine identified a top move (via bestMoveUci or non-empty PV).
  bool get hasTopMove => topMoveUci != null;

  factory PositionScore.fromPvLine(EnginePvLine line) => PositionScore(
        cp: line.cp,
        mate: line.mate,
        bestMoveUci: line.moveUci,
        pv: line.pv,
      );

  factory PositionScore.fromAnalysisResult(EngineAnalysisResult result) {
    final top = result.topLine;
    if (top == null) {
      return const PositionScore();
    }
    return PositionScore(
      cp: top.cp,
      mate: top.mate,
      bestMoveUci: top.moveUci,
      pv: top.pv,
    );
  }
}

/// The result of classifying a single chess move.
class MoveClassificationResult {
  /// Played move in UCI notation.
  final String playedMoveUci;

  /// The assigned qualitative label.
  final ClassificationLabel label;

  /// Win percentage [0.0, 100.0] before the move, from mover's perspective.
  final double winBefore;

  /// Win percentage [0.0, 100.0] after the move, from mover's perspective.
  final double winAfter;

  /// Win percentage loss: max(0.0, winBefore - winAfter).
  final double deltaW;

  /// Continuous accuracy [0.0, 100.0] derived from deltaW.
  final double accuracy;

  /// Whether this move was forced (only 1 legal move available).
  final bool isForced;

  /// Whether this move was an opening book move.
  final bool isBook;

  /// Whether this move matched the engine's top move.
  final bool isEngineTopMove;

  /// Whether this move was a sustained sacrifice (real SEE <= -2 sustained along PV).
  final bool isSacrifice;

  /// Whether this move recaptured on the opponent's previous capture square.
  final bool isRecapture;

  /// Boolean flag (never replaces Mistake/Blunder label):
  /// True when opponent's previous drop D >= 20 and
  /// (my W_after - my win% before opponent's move) < 0.7 * D.
  final bool missedPunishment;

  /// Win% gap between the top/played move and second-best move (when MultiPV 2 ran).
  final double? secondBestDeltaW;

  /// Real Static Exchange Evaluation of the move (P1 N3 B3 R5 Q9), if computed.
  final int? seeScore;

  /// Whether MultiPV 2 candidate search was triggered for this ply.
  final bool usedMultiPv2;

  /// Centipawn loss from mover's perspective (>= 0, mates capped at +/-1000).
  final int cpLoss;

  /// Detected game phase for this ply (optional; set by GameReviewer).
  final GamePhase? phase;

  const MoveClassificationResult({
    this.playedMoveUci = '',
    required this.label,
    required this.winBefore,
    required this.winAfter,
    required this.deltaW,
    required this.accuracy,
    this.isForced = false,
    this.isBook = false,
    this.isEngineTopMove = false,
    this.isSacrifice = false,
    this.isRecapture = false,
    this.missedPunishment = false,
    this.secondBestDeltaW,
    this.seeScore,
    this.usedMultiPv2 = false,
    this.cpLoss = 0,
    this.phase,
  });

  @override
  String toString() =>
      'MoveClassificationResult(move: $playedMoveUci, label: $label, deltaW: ${deltaW.toStringAsFixed(2)}, accuracy: ${accuracy.toStringAsFixed(1)}, isForced: $isForced, missedPunishment: $missedPunishment)';
}

/// Domain Classifier implementing perspective-correct move evaluation and classification.
///
/// SPEC RULES:
/// - Mover M from S_t to S_t+1:
///   W_before = W(score(S_t))
///   W_after = 100 - W(score(S_t+1)); if checkmate -> 100; stalemate/draw -> 50.
///   deltaW = max(0, W_before - W_after).
/// - One eval per position; no second search of played move.
/// - Precedence, first match wins: Book, Brilliant, Great, Best, then bands.
/// - Presets: lichessStyle (default): Best <1 (top move), Excellent 1-2, Good 2-10,
///   Inaccuracy 10-20, Mistake 20-30, Blunder >=30.
/// - A non-top move with deltaW < 1 is Excellent.
/// - If engine top move is unknown (empty PV), never assign Best, Great or Brilliant; use bands only.
/// - Blunder also when W_before >= 60 and W_after <= 40, or a forced mate against mover appears
///   that was not there before.
/// - Saturation guard: if W_before <= 5 and cp loss (mover view, mate capped at 1000) >= 300,
///   force at least Mistake (Blunder at >= 600, configurable).
/// - Forced move: legal-move count == 1 -> Best, skip engine, never Great/Brilliant.
/// - Brilliant: top move or within 1 point of top; real SEE <= -2 sustained along PV;
///   35 <= W_after <= 90; W_before <= 90; not recapture; not forced;
///   no equally good non-sacrificial alternative within 1 point (needs MultiPV 2).
/// - Great: top move; not sacrifice; second-best >= 15 points worse;
///   not forced or simple recapture; W_before <= 90.
/// - Miss: boolean flag missedPunishment, never replaces Mistake/Blunder.
class Classifier {
  final ClassificationConfig config;

  const Classifier({this.config = ClassificationConfig.standard});

  /// Determines whether a position/move triggers MultiPV 2 search:
  /// "MultiPV 2 only on candidates: played move is top-1 and W_before in [20,90], or deltaW>=10."
  bool isMultiPv2Candidate({
    required bool isEngineTopMove,
    required double winBefore,
    required double deltaW,
    bool isForced = false,
    bool isBook = false,
  }) {
    if (isForced || isBook) return false;
    if (deltaW >= config.multiPv2DeltaWThreshold) return true;
    return isEngineTopMove &&
        winBefore >= config.multiPv2MinWinBefore &&
        winBefore <= config.multiPv2MaxWinBefore;
  }

  /// Evaluates and classifies a move played by mover M from position S_t to S_t+1.
  MoveClassificationResult classifyMove({
    required String playedMoveUci,
    required PositionScore moverScoreBefore,
    PositionScore? opponentScoreAfter,
    bool isCheckmateAfter = false,
    bool isDrawAfter = false,
    bool isBook = false,
    int legalMovesCount = 2,
    bool isSacrifice = false,
    bool isRecapture = false,
    double? secondBestDeltaW,
    bool? hasNonSacAlternativeWithin1Point,
    double? previousOpponentDrop,
    double? myWinBeforeOpponent,
    int? seeScore,
    bool usedMultiPv2 = false,
    GamePhase? phase,
  }) {
    final isForced = legalMovesCount == 1;
    final hasBeforeEval =
        moverScoreBefore.cp != null || moverScoreBefore.mate != null;
    final hasAfterEval = opponentScoreAfter != null &&
        (opponentScoreAfter.cp != null || opponentScoreAfter.mate != null);

    // Win% before from mover's perspective
    final winBefore = WinPercent.fromScore(
      cp: moverScoreBefore.cp,
      mate: moverScoreBefore.mate,
    );

    // Win% after from mover's perspective
    final double winAfter;
    if (isCheckmateAfter) {
      winAfter = 100.0;
    } else if (isDrawAfter) {
      winAfter = 50.0;
    } else if (hasAfterEval) {
      final oppWin = WinPercent.fromScore(
        cp: opponentScoreAfter.cp,
        mate: opponentScoreAfter.mate,
      );
      winAfter = 100.0 - oppWin;
    } else {
      // Missing engine evaluation on non-terminal position: preserve baseline safely.
      winAfter = winBefore;
    }

    final deltaW = math.max(0.0, winBefore - winAfter);
    final accuracy = MoveAccuracy.calculate(
      deltaW: deltaW,
      bonus: config.accuracyBonus,
    );

    final topMove = moverScoreBefore.topMoveUci;
    final hasEngineTopMove = isCheckmateAfter || topMove != null;
    final isEngineTopMove = isCheckmateAfter ||
        (hasEngineTopMove && topMove == playedMoveUci);

    final moverCpBefore = _toMoverCp(moverScoreBefore.cp, moverScoreBefore.mate);
    final int moverCpAfter;
    if (isCheckmateAfter) {
      moverCpAfter = 1000;
    } else if (isDrawAfter) {
      moverCpAfter = 0;
    } else if (hasAfterEval) {
      moverCpAfter = -_toMoverCp(opponentScoreAfter.cp, opponentScoreAfter.mate);
    } else {
      moverCpAfter = moverCpBefore;
    }

    final cpLoss = (!isForced &&
            hasBeforeEval &&
            (isCheckmateAfter || isDrawAfter || hasAfterEval))
        ? math.max(0, moverCpBefore - moverCpAfter)
        : 0;

    final missedPunishment = !isForced &&
        !isBook &&
        previousOpponentDrop != null &&
        myWinBeforeOpponent != null &&
        previousOpponentDrop >= config.missMinOpponentDrop &&
        (winAfter - myWinBeforeOpponent) <
            config.missRecoveryRatio * previousOpponentDrop;

    final label = classifyRaw(
      winBefore: winBefore,
      winAfter: winAfter,
      deltaW: deltaW,
      isBook: isBook,
      isForced: isForced,
      isEngineTopMove: isEngineTopMove,
      hasEngineTopMove: hasEngineTopMove,
      moverCpBefore: moverCpBefore,
      moverCpAfter: moverCpAfter,
      moverMateBefore: moverScoreBefore.mate,
      opponentMateAfter: isCheckmateAfter
          ? null
          : (isDrawAfter ? null : opponentScoreAfter?.mate),
      isSacrifice: isSacrifice,
      isRecapture: isRecapture,
      secondBestDeltaW: secondBestDeltaW,
      hasNonSacAlternativeWithin1Point: hasNonSacAlternativeWithin1Point,
      myWinBeforeOpponent: myWinBeforeOpponent,
    );

    return MoveClassificationResult(
      playedMoveUci: playedMoveUci,
      label: label,
      winBefore: winBefore,
      winAfter: winAfter,
      deltaW: deltaW,
      accuracy: accuracy,
      isForced: isForced,
      isBook: isBook,
      isEngineTopMove: isEngineTopMove,
      isSacrifice: isSacrifice,
      isRecapture: isRecapture,
      missedPunishment: missedPunishment,
      secondBestDeltaW: secondBestDeltaW,
      seeScore: seeScore,
      usedMultiPv2: usedMultiPv2,
      cpLoss: cpLoss,
      phase: phase,
    );
  }

  /// Low-level classification logic operating on computed win percentages and scores.
  ClassificationLabel classifyRaw({
    required double winBefore,
    required double winAfter,
    required double deltaW,
    bool isBook = false,
    bool isForced = false,
    bool isEngineTopMove = false,
    bool hasEngineTopMove = true,
    int? moverCpBefore,
    int? moverCpAfter,
    int? moverMateBefore,
    int? opponentMateAfter,
    bool isSacrifice = false,
    bool isRecapture = false,
    double? secondBestDeltaW,
    bool? hasNonSacAlternativeWithin1Point,
    double? myWinBeforeOpponent,
  }) {
    // 1. Precedence first match wins: Book comes first (book still counted in accuracy)
    if (isBook) {
      return ClassificationLabel.book;
    }

    // 2. Forced move: legal-move count == 1 -> Best, never Great/Brilliant
    if (isForced) {
      return ClassificationLabel.best;
    }

    // 3. Blunder checks:
    // a) Opponent forced mate appeared against mover that wasn't there before
    final allowedForcedMate = opponentMateAfter != null &&
        opponentMateAfter > 0 &&
        (moverMateBefore == null || moverMateBefore > 0);

    // b) Blunder swing guard: W_before >= 60 and W_after <= 40
    final collapsedWinningToLost =
        winBefore >= config.blunderSwingBeforeThreshold &&
            winAfter <= config.blunderSwingAfterThreshold;

    // c) DeltaW >= blunder threshold
    final isDeltaBlunder = deltaW >= config.bands.mistakeDeltaMax;

    if (allowedForcedMate || collapsedWinningToLost || isDeltaBlunder) {
      return ClassificationLabel.blunder;
    }

    // 4. Saturation guard:
    // If W_before <= 5 and cp loss (mover view, mate capped at 1000) >= 300,
    // force at least Mistake (Blunder at >= 600, configurable).
    if (winBefore <= config.saturationGuardWinPercent &&
        moverCpBefore != null &&
        moverCpAfter != null) {
      final cpLoss = moverCpBefore - moverCpAfter;
      if (cpLoss >= config.saturationBlunderCpLoss) {
        return ClassificationLabel.blunder;
      }
      if (cpLoss >= config.saturationMistakeCpLoss) {
        return ClassificationLabel.mistake;
      }
    }

    // 5. Special moves (Brilliant, Great):
    // Never when top move is unknown (empty PV), forced, recapture, or W_before > 90.
    final eligibleForSpecial = hasEngineTopMove &&
        !isForced &&
        !isRecapture &&
        winBefore <= config.specialMoveMaxWinPercent;

    if (eligibleForSpecial) {
      // Brilliant: top move or within 1 point of top; real SEE <= -2 sustained along PV;
      // 35 <= W_after <= 90; W_before <= 90; not recapture; not forced;
      // no equally good non-sacrificial alternative within 1 point (requires MultiPV 2).
      if ((isEngineTopMove || deltaW <= config.brilliantTopDeltaMax) &&
          isSacrifice &&
          winAfter >= config.brilliantMinWinAfter &&
          winAfter <= config.specialMoveMaxWinPercent &&
          hasNonSacAlternativeWithin1Point == false) {
        return ClassificationLabel.brilliant;
      }

      // Great: top move; not a sacrifice; second-best >= 15 points worse;
      // not forced or simple recapture; W_before <= 90.
      // "turns the game" variant is gated behind config.turnsTheGameVariant (default OFF).
      final isOnlyGoodMove = secondBestDeltaW != null &&
          secondBestDeltaW >= config.greatSecondBestDeltaMin;
      final turnedGameAround = config.turnsTheGameVariant &&
          myWinBeforeOpponent != null &&
          myWinBeforeOpponent < 45.0 &&
          winAfter >= 55.0;

      if (isEngineTopMove &&
          deltaW < config.bands.bestDeltaMax &&
          !isSacrifice &&
          (isOnlyGoodMove || turnedGameAround)) {
        return ClassificationLabel.great;
      }
    }

    // 6. Best and Bands:
    // If engine top move is unknown (empty PV), never assign Best, Great or Brilliant; use bands only.
    if (!hasEngineTopMove) {
      if (deltaW < config.bands.excellentDeltaMax) {
        return ClassificationLabel.excellent;
      }
    } else {
      // Best: engine top move with deltaW < bestDeltaMax (1.0)
      if (isEngineTopMove && deltaW < config.bands.bestDeltaMax) {
        return ClassificationLabel.best;
      }
      // Non-top move with deltaW < 1 is Excellent.
      if (!isEngineTopMove && deltaW < config.bands.bestDeltaMax) {
        return ClassificationLabel.excellent;
      }
    }

    // Standard deltaW bands
    if (deltaW < config.bands.excellentDeltaMax) {
      return ClassificationLabel.excellent;
    }
    if (deltaW < config.bands.goodDeltaMax) {
      return ClassificationLabel.good;
    }
    if (deltaW < config.bands.inaccuracyDeltaMax) {
      return ClassificationLabel.inaccuracy;
    }
    if (deltaW < config.bands.mistakeDeltaMax) {
      return ClassificationLabel.mistake;
    }

    return ClassificationLabel.blunder;
  }

  static int _toMoverCp(int? cp, int? mate) {
    if (mate != null) {
      if (mate > 0) return 1000;
      if (mate < 0) return -1000;
      return 1000;
    }
    if (cp != null) {
      return cp.clamp(-1000, 1000);
    }
    return 0;
  }
}

/// Service that coordinates single position-pair review while respecting:
/// 1. Forced move rule: legal-move count == 1 -> Best, skips engine call!
/// 2. Terminal position rule: checkmate or draw -> skips engine call for S_t+1!
/// 3. One eval per position; no second search of played move.
class PositionReviewer {
  final EngineServicePort engine;
  final Classifier classifier;

  PositionReviewer({
    required this.engine,
    this.classifier = const Classifier(),
  });

  /// Evaluates and classifies a move transition.
  Future<MoveClassificationResult> reviewMove({
    required String fenBefore,
    required String fenAfter,
    required String playedMoveUci,
    required int legalMovesCount,
    PositionScore? moverScoreBefore,
    bool isCheckmateAfter = false,
    bool isDrawAfter = false,
    bool isBook = false,
    required EngineBudget budget,
    bool isSacrifice = false,
    bool isRecapture = false,
    double? secondBestDeltaW,
    bool? hasNonSacAlternativeWithin1Point,
    double? previousOpponentDrop,
    double? myWinBeforeOpponent,
    int? seeScore,
  }) async {
    // Forced move: legal-move count == 1 -> Best (unless Book), skip engine entirely!
    if (legalMovesCount == 1) {
      final double winBefore = moverScoreBefore != null
          ? WinPercent.fromScore(
              cp: moverScoreBefore.cp,
              mate: moverScoreBefore.mate,
            )
          : 50.0;
      return MoveClassificationResult(
        playedMoveUci: playedMoveUci,
        label: isBook ? ClassificationLabel.book : ClassificationLabel.best,
        winBefore: winBefore,
        winAfter: winBefore,
        deltaW: 0.0,
        accuracy: 100.0,
        isForced: true,
        isBook: isBook,
        isEngineTopMove: true,
      );
    }

    // Evaluate position before move only if not already provided ("One eval per position")
    final scoreBefore = moverScoreBefore ??
        PositionScore.fromAnalysisResult(
          await engine.analyse(fenBefore, budget: budget),
        );

    // Terminal position rule: NEVER call engine on terminal position!
    PositionScore? opponentScoreAfter;
    if (!isCheckmateAfter && !isDrawAfter) {
      final analysisAfter = await engine.analyse(
        fenAfter,
        budget: budget,
      );
      opponentScoreAfter = PositionScore.fromAnalysisResult(analysisAfter);
    }

    return classifier.classifyMove(
      playedMoveUci: playedMoveUci,
      moverScoreBefore: scoreBefore,
      opponentScoreAfter: opponentScoreAfter,
      isCheckmateAfter: isCheckmateAfter,
      isDrawAfter: isDrawAfter,
      isBook: isBook,
      legalMovesCount: legalMovesCount,
      isSacrifice: isSacrifice,
      isRecapture: isRecapture,
      secondBestDeltaW: secondBestDeltaW,
      hasNonSacAlternativeWithin1Point: hasNonSacAlternativeWithin1Point,
      previousOpponentDrop: previousOpponentDrop,
      myWinBeforeOpponent: myWinBeforeOpponent,
      seeScore: seeScore,
    );
  }
}
