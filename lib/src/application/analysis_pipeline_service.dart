import 'package:chess/chess.dart' as ch;
import '../adapters/providers/llama_and_remote_providers.dart';
import '../adapters/storage/sqlite_storage_adapter.dart';
import '../domain/analysis/critical_moment_selector.dart';
import '../domain/analysis/move_classifier.dart';
import '../domain/analysis/phase_detector.dart';
import '../domain/analysis/win_accuracy_calculator.dart';
import '../domain/chess/chess_models.dart';
import '../domain/chess/fen_normalizer.dart';
import '../domain/chess/see_evaluator.dart';
import '../domain/coach/coach_contracts.dart';
import '../domain/tags/tag_detector.dart';
import '../ports/ports.dart';

class AnalysisProgressState {
  final String gameId;
  final int currentPly;
  final int totalPlies;
  final String stage; // 'evaluating','classifying','tagging','explaining','done','paused'
  final bool thermalThrottled;

  const AnalysisProgressState({
    required this.gameId,
    required this.currentPly,
    required this.totalPlies,
    required this.stage,
    this.thermalThrottled = false,
  });

  double get progress =>
      totalPlies <= 0 ? 0.0 : (currentPly / totalPlies).clamp(0.0, 1.0);
}

class DashboardStats {
  final int analysedGamesCount;
  final double averageAccuracy;
  final double blunderRatePer100Moves;
  final double openingAccuracy;
  final double middlegameAccuracy;
  final double endgameAccuracy;
  final double tacticalAwarenessPercent;
  final Map<String, int> motifMissCounts;
  final List<String> weeklyFocusItems; // Story G-2: at most 2 items when >= 10 games analysed
  final String activePresetId;

  const DashboardStats({
    required this.analysedGamesCount,
    required this.averageAccuracy,
    required this.blunderRatePer100Moves,
    required this.openingAccuracy,
    required this.middlegameAccuracy,
    required this.endgameAccuracy,
    required this.tacticalAwarenessPercent,
    required this.motifMissCounts,
    required this.weeklyFocusItems,
    required this.activePresetId,
  });
}

/// Part 11.1: Staged Analysis Pipeline Service.
/// Stages 1-5 run engine, move classification, accuracies, critical moments, and deterministic tags.
/// Stage 6 explains critical moments via the active ExplanationProvider.
/// Engine and LLM never run concurrently (AD-2, NFR-03).
class AnalysisPipelineService {
  final StorageRepository storage;
  final EngineService engine;
  final ProviderRegistry providerRegistry;

  AnalysisPipelineService({
    required this.storage,
    required this.engine,
    required this.providerRegistry,
  });

  Stream<AnalysisProgressState> analyseGame(
    String gameId, {
    CancelToken? cancel,
    bool explainMoments = true,
  }) async* {
    final game = storage.getGame(gameId);
    if (game == null || !game.isAnalysable) return;

    final positions = storage.getPositions(gameId);
    if (positions.length < 2) return;

    final enginePresetId =
        storage.getSetting('engine_preset_id') ?? 'balanced';
    final preset = EnginePresetConfig.byId(enginePresetId);
    final classPresetId =
        storage.getSetting('classification_preset_id') ?? 'lichess';
    final classConfig = ClassificationConfig.byId(classPresetId);
    final ratingBand =
        RatingBand.fromLabel(storage.getSetting('rating_band'));

    storage.updateGameStatus(gameId, 'analysing');
    final totalPlies = positions.length - 1;

    // Stage 2: Engine pass over all positions (with per-position cache reuse for instant resume)
    final evalsByPly = <int, EngineEvalEntity>{};
    for (var i = 0; i < positions.length; i++) {
      if (cancel?.isCancelled == true) {
        yield AnalysisProgressState(
          gameId: gameId,
          currentPly: i,
          totalPlies: totalPlies,
          stage: 'paused',
          thermalThrottled: engine.isThermalThrottled,
        );
        return;
      }

      final pos = positions[i];
      var cached = storage.getEngineEval(pos.positionKey);
      if (cached == null) {
        final rawEval = await engine.evaluatePosition(
          pos.fen,
          preset,
          multiPv: preset.defaultMultiPv,
        );
        cached = EngineEvalEntity(
          positionKey: pos.positionKey,
          cp: rawEval.cp,
          mate: rawEval.mate,
          depth: rawEval.depth,
          nodes: rawEval.nodes,
          pvUci: rawEval.pvUci,
          multipv: rawEval.multipv,
          createdAt: rawEval.createdAt,
        );
        storage.saveEngineEval(cached);
      }
      evalsByPly[pos.ply] = cached;

      yield AnalysisProgressState(
        gameId: gameId,
        currentPly: i,
        totalPlies: totalPlies,
        stage: 'evaluating',
        thermalThrottled: engine.isThermalThrottled,
      );
    }

    // Compute White's Win% at every position to derive sliding-window volatility (Part 11.4 & 19-8)
    final whiteWinPercents = <double>[];
    for (var i = 0; i < positions.length; i++) {
      final ev = evalsByPly[i]!;
      final sideToMoveIsWhite = i.isEven;
      final moverWin =
          WinAccuracyCalculator.winPercentFromScore(cp: ev.cp, mate: ev.mate);
      final whiteWin = sideToMoveIsWhite ? moverWin : (100.0 - moverWin);
      whiteWinPercents.add(whiteWin);
    }
    final volatilities =
        WinAccuracyCalculator.computeVolatilities(whiteWinPercents);

    // Stage 3: Classify moves & compute per-move accuracies
    final moveAnalyses = <MoveAnalysisEntity>[];
    final whiteAccs = <double>[];
    final blackAccs = <double>[];
    final whiteVols = <double>[];
    final blackVols = <double>[];
    final whiteCpLosses = <double>[];
    final blackCpLosses = <double>[];

    final phaseAccs = <String, Map<String, List<double>>>{
      'white': {'Opening': [], 'Middlegame': [], 'Endgame': []},
      'black': {'Opening': [], 'Middlegame': [], 'Endgame': []},
    };
    final labelCounts = <String, Map<String, int>>{
      'white': {},
      'black': {},
    };

    String? prevCaptureSquare;

    for (var ply = 1; ply < positions.length; ply++) {
      final posBefore = positions[ply - 1];
      final posAfter = positions[ply];
      final evalBefore = evalsByPly[ply - 1]!;
      final evalAfter = evalsByPly[ply]!;
      final moverIsWhite = ply.isOdd;

      final winBeforeMover = WinAccuracyCalculator.winPercentFromScore(
        cp: evalBefore.cp,
        mate: evalBefore.mate,
      );
      // evalAfter is from opponent's perspective, so invert to get mover's winAfter
      final oppWinAfter = WinAccuracyCalculator.winPercentFromScore(
        cp: evalAfter.cp,
        mate: evalAfter.mate,
      );
      final winAfterMover = (100.0 - oppWinAfter).clamp(0.0, 100.0);
      final deltaW =
          WinAccuracyCalculator.computeDeltaW(winBeforeMover, winAfterMover);
      final moveAcc = WinAccuracyCalculator.moveAccuracyFromDeltaW(deltaW);

      final epdAfter = FenNormalizer.toEpd(posAfter.fen);
      final isBook = ply <= classConfig.maxBookPly &&
          storage.lookupOpeningByEpd(epdAfter) != null;

      final phase = PhaseDetector.detectPhase(
        fen: posAfter.fen,
        ply: ply,
        isBook: isBook,
      );

      final bestMoveUci = evalBefore.pvUci.isNotEmpty
          ? evalBefore.pvUci.first
          : posAfter.moveUci;
      final isEngineTopMove =
          bestMoveUci != null && bestMoveUci == posAfter.moveUci;

      // Check candidate re-search at MultiPV=2 (Part 19-6)
      double? secondBestDeltaW;
      if (evalBefore.multipv.length >= 2) {
        final secondLine = evalBefore.multipv[1];
        final secondWin = WinAccuracyCalculator.winPercentFromScore(
          cp: secondLine['cp'] as int?,
          mate: secondLine['mate'] as int?,
        );
        secondBestDeltaW = (winBeforeMover - secondWin).clamp(0.0, 100.0);
      } else if (MoveClassifier.isMultiPv2Candidate(
        isEngineTopMove: isEngineTopMove,
        winBefore: winBeforeMover,
        deltaW: deltaW,
      )) {
        final mpv2Eval =
            await engine.evaluatePosition(posBefore.fen, preset, multiPv: 2);
        if (mpv2Eval.multipv.length >= 2) {
          final secondLine = mpv2Eval.multipv[1];
          final secondWin = WinAccuracyCalculator.winPercentFromScore(
            cp: secondLine['cp'] as int?,
            mate: secondLine['mate'] as int?,
          );
          secondBestDeltaW = (winBeforeMover - secondWin).clamp(0.0, 100.0);
        }
      }

      final moveSan = posAfter.moveSan ?? '';
      final destSq = _extractDestSq(moveSan);
      final isRecapture =
          moveSan.contains('x') && prevCaptureSquare == destSq;
      if (moveSan.contains('x')) {
        prevCaptureSquare = destSq;
      } else {
        prevCaptureSquare = null;
      }

      final seeVal = SeeEvaluator.seeOfMove(posBefore.fen, moveSan);
      final isSacrifice = !isRecapture && seeVal <= -2;

      final boardBefore = ch.Chess.fromFEN(posBefore.fen);
      final legalCount = boardBefore.generate_moves().length;

      final mateBeforeForMover = evalBefore.mate;
      final mateAfterForMover =
          evalAfter.mate != null ? -evalAfter.mate! : null;

      final label = MoveClassifier.classify(
        winBefore: winBeforeMover,
        winAfter: winAfterMover,
        deltaW: deltaW,
        isBook: isBook,
        isEngineTopMove: isEngineTopMove,
        isSacrifice: isSacrifice,
        isRecapture: isRecapture,
        isForcedOnlyLegalMove: legalCount <= 1,
        secondBestDeltaW: secondBestDeltaW,
        mateBeforeForMover: mateBeforeForMover,
        mateAfterForMover: mateAfterForMover,
        config: classConfig,
      );

      final vol = ply < volatilities.length ? volatilities[ply] : 1.0;
      final bestSan = _uciToSan(posBefore.fen, bestMoveUci) ?? moveSan;

      final item = MoveAnalysisEntity(
        gameId: gameId,
        ply: ply,
        winBefore: winBeforeMover,
        winAfter: winAfterMover,
        deltaW: deltaW,
        accuracy: moveAcc,
        label: label,
        isBook: isBook,
        isSacrifice: isSacrifice,
        bestMoveUci: bestMoveUci,
        bestMoveSan: bestSan,
        secondBestDeltaW: secondBestDeltaW,
        volatility: vol,
        phase: phase,
        presetId: classConfig.presetId,
      );

      storage.saveMoveAnalysis(item);
      moveAnalyses.add(item);

      // Accumulate side stats
      final cpBeforeMover = evalBefore.mate != null
          ? (evalBefore.mate! > 0 ? 1000 : -1000)
          : (evalBefore.cp ?? 0).clamp(-1000, 1000);
      final cpAfterMover = evalAfter.mate != null
          ? (-evalAfter.mate! > 0 ? 1000 : -1000)
          : (-(evalAfter.cp ?? 0)).clamp(-1000, 1000);
      final cpLoss = (cpBeforeMover - cpAfterMover).clamp(0, 1000).toDouble();

      final sideKey = moverIsWhite ? 'white' : 'black';
      if (moverIsWhite) {
        whiteAccs.add(moveAcc);
        whiteVols.add(vol);
        whiteCpLosses.add(cpLoss);
      } else {
        blackAccs.add(moveAcc);
        blackVols.add(vol);
        blackCpLosses.add(cpLoss);
      }
      phaseAccs[sideKey]![phase.label]!.add(moveAcc);
      labelCounts[sideKey]![label.label] =
          (labelCounts[sideKey]![label.label] ?? 0) + 1;
    }

    // Stage 4: Select Critical Moments (5-8 moments, spacing >= 3 plies)
    final rawMoments = CriticalMomentSelector.selectMoments(
      gameId: gameId,
      moves: moveAnalyses,
      userColor: game.myColor,
    );

    // Stage 5: Tag Critical Moments
    final enrichedMoments = <CriticalMomentEntity>[];
    final allEmittedTags = <TagEntity>[];

    for (final m in rawMoments) {
      final posBefore = positions[m.ply - 1];
      final posAfter = positions[m.ply];
      final ma = moveAnalyses[m.ply - 1];
      final evalAfter = evalsByPly[m.ply]!;
      final evalBefore = evalsByPly[m.ply - 1]!;

      final tags = TagDetector.detectTagsForMoment(
        gameId: gameId,
        ply: m.ply,
        fenBefore: posBefore.fen,
        fenAfterPlayed: posAfter.fen,
        playedMoveSan: posAfter.moveSan ?? '',
        bestMoveUci: ma.bestMoveUci,
        pvUci: evalBefore.pvUci,
        mateAfterPlayed:
            evalAfter.mate != null ? -evalAfter.mate! : null,
        mateOnBestLine: evalBefore.mate,
        phase: ma.phase,
      );

      allEmittedTags.addAll(tags);
      enrichedMoments.add(
        CriticalMomentEntity(
          gameId: gameId,
          ply: m.ply,
          rank: m.rank,
          reason: m.reason,
          tags: tags,
        ),
      );
    }

    storage.saveCriticalMoments(gameId, enrichedMoments, allEmittedTags);

    // Save Game Summary
    final summary = GameSummaryEntity(
      gameId: gameId,
      accWhite: WinAccuracyCalculator.computeCompositeAccuracy(
        moveAccuracies: whiteAccs,
        volatilities: whiteVols,
      ),
      accBlack: WinAccuracyCalculator.computeCompositeAccuracy(
        moveAccuracies: blackAccs,
        volatilities: blackVols,
      ),
      acplWhite: WinAccuracyCalculator.computeAcpl(whiteCpLosses),
      acplBlack: WinAccuracyCalculator.computeAcpl(blackCpLosses),
      phaseAccuracy: {
        'white': phaseAccs['white']!.map(
          (k, list) => MapEntry(
            k,
            list.isEmpty
                ? 100.0
                : list.reduce((a, b) => a + b) / list.length,
          ),
        ),
        'black': phaseAccs['black']!.map(
          (k, list) => MapEntry(
            k,
            list.isEmpty
                ? 100.0
                : list.reduce((a, b) => a + b) / list.length,
          ),
        ),
      },
      counts: labelCounts,
      presetId: classConfig.presetId,
      engineVersion: engine.engineVersion,
    );
    storage.saveGameSummary(summary);
    storage.updateGameStatus(gameId, 'analysed');

    // Stage 6: Explain critical moments via active provider (separate stage from engine per AD-2)
    if (explainMoments) {
      for (final moment in enrichedMoments) {
        if (cancel?.isCancelled == true) break;
        final posBefore = positions[moment.ply - 1];
        final posAfter = positions[moment.ply];
        final ma = moveAnalyses[moment.ply - 1];
        final evalBefore = evalsByPly[moment.ply - 1]!;
        final bestLineSan = _uciLineToSan(posBefore.fen, evalBefore.pvUci);

        final req = CoachRequest(
          gameId: gameId,
          ratingBand: ratingBand,
          userColor: game.myColor,
          ply: moment.ply,
          fen: posBefore.fen,
          moveSan: posAfter.moveSan ?? '',
          classification: ma.label,
          winBefore: ma.winBefore,
          winAfter: ma.winAfter,
          deltaW: ma.deltaW,
          bestMoveSan: ma.bestMoveSan ?? (posAfter.moveSan ?? ''),
          bestLineSan: bestLineSan,
          phase: ma.phase,
          materialChange: SeeEvaluator.materialBalanceForSide(
                posAfter.fen,
                game.myColor.name,
              ) -
              SeeEvaluator.materialBalanceForSide(
                posBefore.fen,
                game.myColor.name,
              ),
          tags: moment.tags,
          openingName: game.openingName,
        );

        await providerRegistry.explainMomentWithFallback(req, cancel: cancel);
      }
    }

    yield AnalysisProgressState(
      gameId: gameId,
      currentPly: totalPlies,
      totalPlies: totalPlies,
      stage: 'done',
      thermalThrottled: engine.isThermalThrottled,
    );
  }

  /// Story G-1 & G-2 & Part 19-5: Cross-game Weakness Dashboard and Weekly Focus.
  DashboardStats computeDashboardStats({String? timeClassFilter}) {
    final activePresetId =
        storage.getSetting('classification_preset_id') ?? 'lichess';
    final config = ClassificationConfig.byId(activePresetId);
    final analysedGames = storage.listGames(
      timeClassFilter: timeClassFilter,
      analysedOnly: true,
    );

    if (analysedGames.isEmpty) {
      return DashboardStats(
        analysedGamesCount: 0,
        averageAccuracy: 0.0,
        blunderRatePer100Moves: 0.0,
        openingAccuracy: 0.0,
        middlegameAccuracy: 0.0,
        endgameAccuracy: 0.0,
        tacticalAwarenessPercent: 100.0,
        motifMissCounts: const {},
        weeklyFocusItems: const [],
        activePresetId: activePresetId,
      );
    }

    var totalAcc = 0.0;
    var userTotalMoves = 0;
    var userBlunders = 0;
    final opAccs = <double>[];
    final midAccs = <double>[];
    final endAccs = <double>[];
    var oppMistakes = 0;
    var oppMistakesCapitalised = 0;
    final motifMisses = <String, int>{};

    for (final g in analysedGames) {
      final sum = storage.getGameSummary(g.id);
      final moves = storage.getMoveAnalyses(g.id);
      final sideKey = g.myColor == SideColor.w ? 'white' : 'black';

      if (sum != null) {
        totalAcc += g.myColor == SideColor.w ? sum.accWhite : sum.accBlack;
        final ph = sum.phaseAccuracy[sideKey] ?? {};
        if (ph.containsKey('Opening')) opAccs.add(ph['Opening']!);
        if (ph.containsKey('Middlegame')) midAccs.add(ph['Middlegame']!);
        if (ph.containsKey('Endgame')) endAccs.add(ph['Endgame']!);
      }

      for (var i = 0; i < moves.length; i++) {
        final m = moves[i];
        if (m.moverColor == g.myColor) {
          userTotalMoves++;
          // Part 19-5: Dashboard blunder rate uses the active preset threshold
          if (m.deltaW >= config.blunderThreshold ||
              m.label == MoveClassification.blunder) {
            userBlunders++;
          }
          if (m.label.isNegative) {
            final tags = storage.getGameTags(g.id, ply: m.ply);
            for (final t in tags) {
              if (t.code != 'PHASE') {
                motifMisses[t.code] = (motifMisses[t.code] ?? 0) + 1;
              }
            }
          }
        } else {
          // Opponent mistake check for Tactical Awareness (Part 11.9: next move recovers >= 70% of opponent's drop)
          if (m.deltaW >= config.mistakeThreshold && i + 1 < moves.length) {
            oppMistakes++;
            final userReply = moves[i + 1];
            if (userReply.deltaW <= 0.30 * m.deltaW) {
              oppMistakesCapitalised++;
            }
          }
        }
      }
    }

    final avgAcc = totalAcc / analysedGames.length;
    final blunderRate =
        userTotalMoves > 0 ? (userBlunders * 100.0 / userTotalMoves) : 0.0;
    final tacticalAwareness = oppMistakes > 0
        ? (oppMistakesCapitalised * 100.0 / oppMistakes)
        : 100.0;

    // Story G-2: Weekly focus — at most 2 focus items from top weakness categories in last 20 analysed games,
    // hidden until 10 analysed games exist.
    final focusItems = <String>[];
    if (analysedGames.length >= 10) {
      final sortedMotifs = motifMisses.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final entry in sortedMotifs.take(2)) {
        focusItems.add(_deterministicFocusText(entry.key, entry.value));
      }
      if (focusItems.isEmpty && blunderRate > 5.0) {
        focusItems.add(
          'Blunder check: Pause 5 seconds before each capture to verify whether your piece is defended.',
        );
      }
    }

    return DashboardStats(
      analysedGamesCount: analysedGames.length,
      averageAccuracy: avgAcc,
      blunderRatePer100Moves: blunderRate,
      openingAccuracy:
          opAccs.isEmpty ? 0.0 : opAccs.reduce((a, b) => a + b) / opAccs.length,
      middlegameAccuracy: midAccs.isEmpty
          ? 0.0
          : midAccs.reduce((a, b) => a + b) / midAccs.length,
      endgameAccuracy: endAccs.isEmpty
          ? 0.0
          : endAccs.reduce((a, b) => a + b) / endAccs.length,
      tacticalAwarenessPercent: tacticalAwareness,
      motifMissCounts: motifMisses,
      weeklyFocusItems: focusItems.take(2).toList(),
      activePresetId: activePresetId,
    );
  }

  static String _deterministicFocusText(String tagCode, int count) {
    switch (tagCode) {
      case 'HANGING_PIECE':
        return 'Piece safety ($count misses): Before moving, verify every undefended non-pawn piece.';
      case 'FORK_KNIGHT':
      case 'FORK_PAWN':
        return 'Double attacks ($count misses): Scan for knight and pawn fork squares on both sides.';
      case 'PIN_ABSOLUTE':
      case 'PIN_RELATIVE':
        return 'Pin awareness ($count misses): Step out of slider lines with your king and queen.';
      case 'BACK_RANK':
        return 'Back-rank safety ($count misses): Create a flight square (luft) when heavy pieces remain.';
      default:
        return 'Focus on $tagCode ($count occurrences in recent games).';
    }
  }

  static String _extractDestSq(String san) {
    final m = RegExp(r'([a-h][1-8])').allMatches(san);
    return m.isNotEmpty ? m.last.group(1)! : 'e4';
  }

  static String? _uciToSan(String fen, String? uci) {
    if (uci == null || uci.isEmpty) return null;
    try {
      final game = ch.Chess.fromFEN(fen);
      for (final m in game.generate_moves()) {
        final cand =
            '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}';
        if (cand.toLowerCase() == uci.toLowerCase()) {
          return game.move_to_san(m);
        }
      }
    } catch (_) {}
    return uci;
  }

  static List<String> _uciLineToSan(String startFen, List<String> pvUci) {
    final out = <String>[];
    try {
      final game = ch.Chess.fromFEN(startFen);
      for (final uci in pvUci.take(6)) {
        ch.Move? match;
        for (final m in game.generate_moves()) {
          final cand =
              '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}';
          if (cand.toLowerCase() == uci.toLowerCase()) {
            match = m;
            break;
          }
        }
        if (match == null) break;
        out.add(game.move_to_san(match));
        game.move(match);
      }
    } catch (_) {}
    return out;
  }
}
