import 'dart:math' as math;
import 'package:chess/chess.dart' as ch;
import 'classification_config.dart';
import 'classifier.dart';
import 'phase_detector.dart';
import 'see.dart';
import 'win_percent.dart';
import '../ports/engine_service.dart';
import '../ports/opening_book.dart';

/// Complete per-ply analysis output for a single chess game.
class GameReviewResult {
  final String initialFen;
  final List<MoveClassificationResult> plies;
  final String engineVersion;

  const GameReviewResult({
    required this.initialFen,
    required this.plies,
    required this.engineVersion,
  });
}

class _PreparedPly {
  final int plyNumber;
  final String fenBefore;
  final String fenAfter;
  final String playedMoveUci;
  final int legalMovesCount;
  final bool isCheckmateAfter;
  final bool isDrawAfter;
  final bool isBook;
  final bool isRecapture;
  final GamePhase phase;

  const _PreparedPly({
    required this.plyNumber,
    required this.fenBefore,
    required this.fenAfter,
    required this.playedMoveUci,
    required this.legalMovesCount,
    required this.isCheckmateAfter,
    required this.isDrawAfter,
    required this.isBook,
    required this.isRecapture,
    required this.phase,
  });
}

/// Deterministic game review orchestrator implementing the full specification:
/// - Legal move validation and strictly derived `isForced` (legalMovesCount == 1)
/// - EPD position-keyed opening book lookup
/// - One primary eval per position (carrying S_t+1 forward as S_t for next ply)
/// - Skips engine on forced moves and terminal positions
/// - Triggers MultiPV 2 strictly on candidates:
///   (played move is top-1 and W_before in [20, 90]) || deltaW >= 10
/// - Evaluates real SEE <= -2 sustained along PV for sacrifices
/// - Tracks `missedPunishment` (Miss flag) across consecutive turns
/// - Caches analyses by normalized FEN + engine version + settings hash + MultiPV count
class GameReviewer {
  static const String kStandardStartFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  final EngineServicePort engine;
  final OpeningBookPort? openingBook;
  final Classifier classifier;
  final Map<String, EngineAnalysisResult>? externalEvalCache;

  GameReviewer({
    required this.engine,
    this.openingBook,
    this.classifier = const Classifier(),
    this.externalEvalCache,
  });

  /// Reviews a sequence of UCI moves starting from [initialFen].
  ///
  /// Throws [FormatException] if any move in [movesUci] is illegal.
  Future<GameReviewResult> reviewGame({
    String initialFen = kStandardStartFen,
    required List<String> movesUci,
    required EngineBudget budget,
  }) async {
    final preparedPlies = _preparePlies(initialFen, movesUci);
    if (preparedPlies.isEmpty) {
      return GameReviewResult(
        initialFen: initialFen,
        plies: const [],
        engineVersion: engine.engineVersion,
      );
    }

    await engine.newGame();
    final cache = externalEvalCache ?? <String, EngineAnalysisResult>{};

    final results = <MoveClassificationResult>[];
    EngineAnalysisResult? carriedEvalForCurrentBefore;

    for (final ply in preparedPlies) {
      // Precedence & forced-move rules:
      // If only 1 legal move exists (isForced), skip the engine entirely!
      if (ply.legalMovesCount == 1) {
        final double winBefore = carriedEvalForCurrentBefore?.topLine != null
            ? WinPercent.fromScore(
                cp: carriedEvalForCurrentBefore!.topLine!.cp,
                mate: carriedEvalForCurrentBefore.topLine!.mate,
              )
            : 50.0;
        final double winAfter = ply.isCheckmateAfter
            ? 100.0
            : (ply.isDrawAfter ? 50.0 : winBefore);

        results.add(MoveClassificationResult(
          playedMoveUci: ply.playedMoveUci,
          label: ply.isBook
              ? ClassificationLabel.book
              : ClassificationLabel.best,
          winBefore: winBefore,
          winAfter: winAfter,
          deltaW: 0.0,
          accuracy: 100.0,
          isForced: true,
          isBook: ply.isBook,
          isEngineTopMove: true,
          isRecapture: ply.isRecapture,
          missedPunishment: false,
          cpLoss: 0,
          phase: ply.phase,
        ));

        // After a forced move skipped evaluation of fenAfter, do not carry stale eval.
        carriedEvalForCurrentBefore = null;
        continue;
      }

      // Evaluate S_t (fenBefore) at MultiPV 1 only if not carried forward from previous ply
      final evalBefore = carriedEvalForCurrentBefore ??
          await _getCachedAnalysis(
            cache,
            fen: ply.fenBefore,
            multiPv: 1,
            budget: budget,
          );

      // Evaluate S_{t+1} (fenAfter) at MultiPV 1 unless terminal (checkmate/draw)
      EngineAnalysisResult? evalAfter;
      if (!ply.isCheckmateAfter && !ply.isDrawAfter) {
        evalAfter = await _getCachedAnalysis(
          cache,
          fen: ply.fenAfter,
          multiPv: 1,
          budget: budget,
        );
      }

      final scoreBefore = PositionScore.fromAnalysisResult(evalBefore);
      final opponentScoreAfter = evalAfter != null
          ? PositionScore.fromAnalysisResult(evalAfter)
          : null;
      final hasAfterEval = opponentScoreAfter != null &&
          (opponentScoreAfter.cp != null || opponentScoreAfter.mate != null);

      final winBefore = WinPercent.fromScore(
        cp: scoreBefore.cp,
        mate: scoreBefore.mate,
      );
      final double winAfter;
      if (ply.isCheckmateAfter) {
        winAfter = 100.0;
      } else if (ply.isDrawAfter) {
        winAfter = 50.0;
      } else if (hasAfterEval) {
        winAfter = 100.0 -
            WinPercent.fromScore(
              cp: opponentScoreAfter.cp,
              mate: opponentScoreAfter.mate,
            );
      } else {
        winAfter = winBefore;
      }
      final deltaW = math.max(0.0, winBefore - winAfter);

      final topMove = scoreBefore.topMoveUci;
      final isEngineTopMove =
          ply.isCheckmateAfter || (topMove != null && topMove == ply.playedMoveUci);

      // Compute SEE and PV-sustained sacrifice status
      final pvAfterPlayed = (opponentScoreAfter != null &&
              opponentScoreAfter.pv.isNotEmpty)
          ? opponentScoreAfter.pv
          : (isEngineTopMove && scoreBefore.pv.length > 1
              ? scoreBefore.pv.skip(1).toList()
              : const <String>[]);

      final seeScore = See.evaluateMove(ply.fenBefore, ply.playedMoveUci);
      final isSacrifice = !ply.isRecapture &&
          See.isSacrificeSustainedAlongPv(
            fenBefore: ply.fenBefore,
            fenAfter: ply.fenAfter,
            playedMoveUci: ply.playedMoveUci,
            pvAfter: pvAfterPlayed,
            seeThreshold: classifier.config.brilliantSeeThreshold,
            maxPvPlies: classifier.config.brilliantSustainedPvPlies,
          );

      // Trigger MultiPV 2 strictly on candidates
      final runMultiPv2 = classifier.isMultiPv2Candidate(
        isEngineTopMove: isEngineTopMove,
        winBefore: winBefore,
        deltaW: deltaW,
        isForced: false,
        isBook: ply.isBook,
      );

      double? secondBestDeltaW;
      bool? hasNonSacAlternativeWithin1Point;
      var usedMultiPv2 = false;

      EngineAnalysisResult mpvSource = evalBefore;
      if (runMultiPv2) {
        usedMultiPv2 = true;
        mpvSource = evalBefore.lines.length >= 2
            ? evalBefore
            : await _getCachedAnalysis(
                cache,
                fen: ply.fenBefore,
                multiPv: 2,
                budget: budget,
              );
      }

      if (mpvSource.lines.length >= 2) {
        final alternatives = mpvSource.lines
            .where((l) => l.moveUci.toLowerCase() != ply.playedMoveUci)
            .toList();
        if (alternatives.isNotEmpty) {
          final bestAlt = alternatives.first;
          secondBestDeltaW = math.max(0.0, winBefore - bestAlt.winPercent);

          var foundNonSacAltWithin1Point = false;
          for (final alt in alternatives) {
            final gap = winAfter - alt.winPercent;
            if (gap <= classifier.config.brilliantAlternativeDeltaMax) {
              if (!_isLineSustainedSacrifice(ply.fenBefore, alt)) {
                foundNonSacAltWithin1Point = true;
                break;
              }
            }
          }
          hasNonSacAlternativeWithin1Point = foundNonSacAltWithin1Point;
        }
      } else if (!isEngineTopMove && evalBefore.topLine != null) {
        // MultiPV 1 already exposes a strictly higher-ranked top move.
        // If top-1 is non-sacrificial and played move is within 1 point, it blocks Brilliant.
        final topAlt = evalBefore.topLine!;
        if ((winAfter - topAlt.winPercent) <=
                classifier.config.brilliantAlternativeDeltaMax &&
            !_isLineSustainedSacrifice(ply.fenBefore, topAlt)) {
          hasNonSacAlternativeWithin1Point = true;
        }
      }

      final previousResult = results.isNotEmpty ? results.last : null;
      final previousOpponentDrop = previousResult?.deltaW;
      final myWinBeforeOpponent =
          previousResult != null ? (100.0 - previousResult.winBefore) : null;

      results.add(
        classifier.classifyMove(
          playedMoveUci: ply.playedMoveUci,
          moverScoreBefore: scoreBefore,
          opponentScoreAfter: opponentScoreAfter,
          isCheckmateAfter: ply.isCheckmateAfter,
          isDrawAfter: ply.isDrawAfter,
          isBook: ply.isBook,
          legalMovesCount: ply.legalMovesCount,
          isSacrifice: isSacrifice,
          isRecapture: ply.isRecapture,
          secondBestDeltaW: secondBestDeltaW,
          hasNonSacAlternativeWithin1Point: hasNonSacAlternativeWithin1Point,
          previousOpponentDrop: previousOpponentDrop,
          myWinBeforeOpponent: myWinBeforeOpponent,
          seeScore: seeScore,
          usedMultiPv2: usedMultiPv2,
          phase: ply.phase,
        ),
      );

      // Zero-sum continuity: carry primary MultiPV 1 evalAfter forward to next ply!
      carriedEvalForCurrentBefore = evalAfter;
    }

    return GameReviewResult(
      initialFen: initialFen,
      plies: results,
      engineVersion: engine.engineVersion,
    );
  }

  List<_PreparedPly> _preparePlies(String initialFen, List<String> movesUci) {
    final game = ch.Chess.fromFEN(initialFen);
    final startPlyOffset =
        ((game.move_number - 1).clamp(0, 10000) * 2) +
            (game.turn == ch.Color.BLACK ? 1 : 0);
    final plies = <_PreparedPly>[];

    var prevWasCapture = false;
    String? prevToSquare;

    for (var i = 0; i < movesUci.length; i++) {
      final fenBefore = game.fen;
      final legalMoves = game.generate_moves();
      final uciLower = movesUci[i].trim().toLowerCase();

      ch.Move? playedMove;
      for (final m in legalMoves) {
        if (See.moveToUci(m) == uciLower) {
          playedMove = m;
          break;
        }
      }
      if (playedMove == null) {
        throw FormatException(
          'Illegal move at ply ${i + 1}: "$uciLower" for position "$fenBefore"',
        );
      }

      final currentWasCapture = playedMove.captured != null ||
          (playedMove.flags & ch.Chess.BITS_EP_CAPTURE) != 0;
      final currentToSquare = playedMove.toAlgebraic.toLowerCase();
      final isRecapture = prevWasCapture &&
          currentWasCapture &&
          prevToSquare == currentToSquare;

      game.make_move(playedMove);
      final fenAfter = game.fen;
      final plyNum = startPlyOffset + i + 1;
      final isCheckmateAfter = game.in_checkmate;
      final isDrawAfter = !isCheckmateAfter && game.in_draw;
      final isBook = openingBook?.lookupByFen(fenAfter) != null;
      final phase = PhaseDetector.detect(
        fen: fenAfter,
        ply: plyNum,
        isBook: isBook,
      );

      plies.add(_PreparedPly(
        plyNumber: plyNum,
        fenBefore: fenBefore,
        fenAfter: fenAfter,
        playedMoveUci: uciLower,
        legalMovesCount: legalMoves.length,
        isCheckmateAfter: isCheckmateAfter,
        isDrawAfter: isDrawAfter,
        isBook: isBook,
        isRecapture: isRecapture,
        phase: phase,
      ));

      prevWasCapture = currentWasCapture;
      prevToSquare = currentToSquare;
    }

    return plies;
  }

  Future<EngineAnalysisResult> _getCachedAnalysis(
    Map<String, EngineAnalysisResult> cache, {
    required String fen,
    required int multiPv,
    required EngineBudget budget,
  }) async {
    final cacheKey = EngineAnalysisResult.computeCacheKey(
      normalizedFen: fen,
      engineVersion: engine.engineVersion,
      budget: budget,
      multiPv: multiPv,
    );
    final existing = cache[cacheKey];
    if (existing != null) {
      return existing;
    }
    final result = await engine.analyse(
      fen,
      multiPv: multiPv,
      budget: budget,
    );
    cache[cacheKey] = result;
    return result;
  }

  bool _isLineSustainedSacrifice(String fenBefore, EnginePvLine line) {
    final moveUci = line.moveUci.toLowerCase();
    final see = See.evaluateMove(fenBefore, moveUci);
    if (see == null || see > classifier.config.brilliantSeeThreshold) {
      return false;
    }
    if (line.pv.length < 2) {
      return false;
    }

    final game = ch.Chess.fromFEN(fenBefore);
    final move = See.findLegalMove(game, moveUci);
    if (move == null) return false;
    game.make_move(move);
    final fenAfterAlt = game.fen;

    return See.isSacrificeSustainedAlongPv(
      fenBefore: fenBefore,
      fenAfter: fenAfterAlt,
      playedMoveUci: moveUci,
      pvAfter: line.pv.skip(1).toList(),
      seeThreshold: classifier.config.brilliantSeeThreshold,
      maxPvPlies: classifier.config.brilliantSustainedPvPlies,
    );
  }
}
