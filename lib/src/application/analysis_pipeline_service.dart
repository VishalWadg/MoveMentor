import 'package:chess/chess.dart' as ch;
import 'package:chess_review_core/chess_review_core.dart' as core;
import '../adapters/engine/stockfish_engine_adapter.dart';
import '../adapters/providers/llama_and_remote_providers.dart';
import '../adapters/storage/sqlite_storage_adapter.dart';
import '../domain/analysis/critical_moment_selector.dart';
import '../domain/analysis/move_classifier.dart';
import '../domain/chess/chess_models.dart';
import '../domain/chess/see_evaluator.dart';
import '../domain/coach/coach_contracts.dart';
import '../domain/tags/tag_detector.dart';
import '../ports/ports.dart';
import 'game_review_runner.dart';

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
  final core.OpeningBookPort? openingBook;
  final bool defaultUseNewClassifier;
  final core.ClassificationConfig? defaultCoreConfig;
  final core.EngineBudget? defaultCoreBudget;

  AnalysisPipelineService({
    required this.storage,
    required this.engine,
    required this.providerRegistry,
    this.openingBook,
    this.defaultUseNewClassifier = true,
    this.defaultCoreConfig,
    this.defaultCoreBudget,
  });

  bool resolveUseNewClassifier({bool? override}) {
    if (override != null) return override;
    final raw = storage.getSetting('use_new_classifier');
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    return defaultUseNewClassifier;
  }

  core.ClassificationConfig resolveCoreConfig(String classPresetId) =>
      GameReviewRunner.resolveCoreConfig(
        classPresetId,
        base: defaultCoreConfig,
      );

  core.EngineBudget resolveCoreBudget(EnginePresetConfig preset) =>
      GameReviewRunner.resolveCoreBudget(preset, override: defaultCoreBudget);

  Stream<AnalysisProgressState> analyseGame(
    String gameId, {
    CancelToken? cancel,
    bool explainMoments = true,
    bool? useNewClassifier,
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

    final ExecutedGameReview? executed;
    if (resolveUseNewClassifier(override: useNewClassifier)) {
      try {
        executed = await GameReviewRunner.runNewCore(
          gameId: gameId,
          positions: positions,
          storage: storage,
          engine: engine,
          enginePreset: preset,
          legacyConfig: classConfig,
          openingBook: openingBook,
          coreConfigOverride: resolveCoreConfig(classPresetId),
          coreBudgetOverride: resolveCoreBudget(preset),
          cancel: cancel,
        );
      } on EngineCancelledException {
        yield AnalysisProgressState(
          gameId: gameId,
          currentPly: 0,
          totalPlies: totalPlies,
          stage: 'paused',
          thermalThrottled: engine.isThermalThrottled,
        );
        return;
      }
    } else {
      executed = await GameReviewRunner.runLegacy(
        gameId: gameId,
        positions: positions,
        storage: storage,
        engine: engine,
        enginePreset: preset,
        classConfig: classConfig,
        cancel: cancel,
      );
    }

    if (executed == null || cancel?.isCancelled == true) {
      yield AnalysisProgressState(
        gameId: gameId,
        currentPly: 0,
        totalPlies: totalPlies,
        stage: 'paused',
        thermalThrottled: engine.isThermalThrottled,
      );
      return;
    }

    final evalsByPly = executed.evalsByPly;
    final moveAnalyses = executed.moveAnalyses;
    final summary = executed.summary;

    yield AnalysisProgressState(
      gameId: gameId,
      currentPly: totalPlies,
      totalPlies: totalPlies,
      stage: 'evaluating',
      thermalThrottled: engine.isThermalThrottled,
    );

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
