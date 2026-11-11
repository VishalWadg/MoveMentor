import 'dart:math' as math;
import 'package:chess/chess.dart' as ch;
import 'package:chess_review_core/chess_review_core.dart' as core;
import '../adapters/engine/stockfish_engine_adapter.dart';
import '../adapters/storage/opening_book_adapter.dart';
import '../adapters/storage/sqlite_storage_adapter.dart';
import '../domain/analysis/move_classifier.dart';
import '../domain/chess/chess_models.dart';
import '../domain/chess/pgn_parser.dart';
import '../ports/ports.dart';
import 'game_review_runner.dart';

/// Sample PGN specification for side-by-side classifier benchmarking.
class ComparisonGameInput {
  final String id;
  final String title;
  final String pgn;

  const ComparisonGameInput({
    required this.id,
    required this.title,
    required this.pgn,
  });
}

/// Detailed per-ply disagreement record between the legacy and new classifiers.
class PlyDisagreement {
  final String gameTitle;
  final int ply;
  final String side;
  final String moveSan;
  final MoveClassification oldLabel;
  final MoveClassification newLabel;
  final double deltaW;
  final double oldWinBefore;
  final double newWinBefore;
  final String reasonCategory;

  const PlyDisagreement({
    required this.gameTitle,
    required this.ply,
    required this.side,
    required this.moveSan,
    required this.oldLabel,
    required this.newLabel,
    required this.deltaW,
    required this.oldWinBefore,
    required this.newWinBefore,
    required this.reasonCategory,
  });
}

/// Per-alignment empirical behavior statistics across the game corpus.
class AlignmentEmpiricalStats {
  final core.WindowAlignment alignment;
  final double meanCompositeWhite;
  final double meanCompositeBlack;
  final double meanErrorMoveWeight;
  final double meanQuietMoveWeight;
  final double weightDiscriminationRatio;
  final double postBlunderSpilloverWeight;
  final double preBlunderSpilloverWeight;
  final int errorMovesCount;
  final int quietMovesCount;

  const AlignmentEmpiricalStats({
    required this.alignment,
    required this.meanCompositeWhite,
    required this.meanCompositeBlack,
    required this.meanErrorMoveWeight,
    required this.meanQuietMoveWeight,
    required this.weightDiscriminationRatio,
    required this.postBlunderSpilloverWeight,
    required this.preBlunderSpilloverWeight,
    required this.errorMovesCount,
    required this.quietMovesCount,
  });
}

/// Per-game comparison results (old vs new classifier + 3 window alignments).
class GameComparisonResult {
  final String gameId;
  final String title;
  final int pliesCount;
  final GameSummaryEntity oldSummary;
  final GameSummaryEntity newSummary;
  final int oldMissedPunishments;
  final int newMissedPunishments;
  final List<MoveAnalysisEntity> oldPlies;
  final List<MoveAnalysisEntity> newPlies;
  final core.GameReviewResult coreReview;
  final Map<core.WindowAlignment, core.GameAggregates> aggregatesByAlignment;
  final List<PlyDisagreement> disagreements;

  const GameComparisonResult({
    required this.gameId,
    required this.title,
    required this.pliesCount,
    required this.oldSummary,
    required this.newSummary,
    required this.oldMissedPunishments,
    required this.newMissedPunishments,
    required this.oldPlies,
    required this.newPlies,
    required this.coreReview,
    required this.aggregatesByAlignment,
    required this.disagreements,
  });
}

/// Complete corpus-wide side-by-side comparison report.
class ClassifierComparisonReport {
  final String engineVersion;
  final core.EngineBudget budget;
  final List<GameComparisonResult> games;
  final int totalPlies;
  final int exactMatchPlies;

  /// 9x9 matrix: `confusionMatrix[oldLabel][newLabel] = count`.
  final Map<MoveClassification, Map<MoveClassification, int>> confusionMatrix;
  final Map<MoveClassification, int> oldDistribution;
  final Map<MoveClassification, int> newDistribution;
  final Map<String, int> discrepancyCategoryCounts;
  final List<PlyDisagreement> sampleDisagreements;
  final Map<core.WindowAlignment, AlignmentEmpiricalStats> alignmentStats;

  const ClassifierComparisonReport({
    required this.engineVersion,
    required this.budget,
    required this.games,
    required this.totalPlies,
    required this.exactMatchPlies,
    required this.confusionMatrix,
    required this.oldDistribution,
    required this.newDistribution,
    required this.discrepancyCategoryCounts,
    required this.sampleDisagreements,
    required this.alignmentStats,
  });

  double get agreementRate =>
      totalPlies == 0 ? 1.0 : (exactMatchPlies / totalPlies);

  String toMarkdownReport() {
    final sb = StringBuffer();
    sb.writeln('# Side-by-Side Classifier Comparison Report');
    sb.writeln('- Engine: `$engineVersion`');
    sb.writeln(
      '- Budget: `nodes=${budget.nodes}, threads=${budget.threads}, hashMb=${budget.hashMb}`',
    );
    sb.writeln(
      '- Corpus: `${games.length}` games, `$totalPlies` total plies, agreement `${(agreementRate * 100).toStringAsFixed(1)}%` ($exactMatchPlies/$totalPlies)',
    );
    sb.writeln();

    sb.writeln('## Per-Game Metrics (Old vs New [centred])');
    sb.writeln(
      '| Game | Plies | White Acc (Old -> New) | Black Acc (Old -> New) | White ACPL (Old -> New) | Black ACPL (Old -> New) | Bril/Great (Old -> New) | Miss (Old -> New) |',
    );
    sb.writeln('|---|---:|---|---|---|---|---|---|');
    for (final g in games) {
      final oldBr = g.oldPlies
          .where((p) => p.label == MoveClassification.brilliant)
          .length;
      final newBr = g.newPlies
          .where((p) => p.label == MoveClassification.brilliant)
          .length;
      final oldGr =
          g.oldPlies.where((p) => p.label == MoveClassification.great).length;
      final newGr =
          g.newPlies.where((p) => p.label == MoveClassification.great).length;
      sb.writeln(
        '| ${g.title} | ${g.pliesCount} | '
        '${g.oldSummary.accWhite.toStringAsFixed(1)}% -> ${g.newSummary.accWhite.toStringAsFixed(1)}% | '
        '${g.oldSummary.accBlack.toStringAsFixed(1)}% -> ${g.newSummary.accBlack.toStringAsFixed(1)}% | '
        '${g.oldSummary.acplWhite.toStringAsFixed(1)} -> ${g.newSummary.acplWhite.toStringAsFixed(1)} | '
        '${g.oldSummary.acplBlack.toStringAsFixed(1)} -> ${g.newSummary.acplBlack.toStringAsFixed(1)} | '
        '$oldBr/$oldGr -> $newBr/$newGr | '
        '${g.oldMissedPunishments} -> ${g.newMissedPunishments} |',
      );
    }
    sb.writeln();

    sb.writeln('## Phase-Wise Accuracy Comparison');
    sb.writeln(
      '| Game | Side | Opening (Old -> New) | Middlegame (Old -> New) | Endgame (Old -> New) |',
    );
    sb.writeln('|---|---|---|---|---|');
    for (final g in games) {
      for (final side in ['white', 'black']) {
        String fmtPhase(String phase) {
          final oldV = g.oldSummary.phaseAccuracy[side]?[phase];
          final newV = g.newSummary.phaseAccuracy[side]?[phase];
          final oldStr = oldV != null ? '${oldV.toStringAsFixed(1)}%' : 'N/A';
          final newStr = newV != null ? '${newV.toStringAsFixed(1)}%' : 'N/A';
          return '$oldStr -> $newStr';
        }

        sb.writeln(
          '| ${g.title} | ${side == 'white' ? 'White' : 'Black'} | '
          '${fmtPhase('Opening')} | ${fmtPhase('Middlegame')} | ${fmtPhase('Endgame')} |',
        );
      }
    }
    sb.writeln();

    sb.writeln('## Label Distribution');
    sb.writeln('| Label | Old Count (%) | New Count (%) | Delta |');
    sb.writeln('|---|---:|---:|---:|');
    for (final label in MoveClassification.values) {
      final oldC = oldDistribution[label] ?? 0;
      final newC = newDistribution[label] ?? 0;
      final oldPct = totalPlies == 0 ? 0.0 : oldC * 100.0 / totalPlies;
      final newPct = totalPlies == 0 ? 0.0 : newC * 100.0 / totalPlies;
      final diff = newC - oldC;
      final sign = diff >= 0 ? '+$diff' : '$diff';
      sb.writeln(
        '| ${label.label} | $oldC (${oldPct.toStringAsFixed(1)}%) | '
        '$newC (${newPct.toStringAsFixed(1)}%) | $sign |',
      );
    }
    sb.writeln();

    sb.writeln('## Confusion Matrix (Rows = Old Baseline, Cols = New Classifier)');
    final headers = MoveClassification.values.map((l) => l.label).join(' | ');
    final sep = MoveClassification.values.map((_) => '---:').join('|');
    sb.writeln('| Old \\\\ New | $headers |');
    sb.writeln('|---| $sep |');
    for (final oldL in MoveClassification.values) {
      final row = MoveClassification.values
          .map((newL) => '${confusionMatrix[oldL]?[newL] ?? 0}')
          .join(' | ');
      sb.writeln('| **${oldL.label}** | $row |');
    }
    sb.writeln();

    sb.writeln('## Empirical Window Alignment Comparison');
    sb.writeln(
      '| Alignment | Mean White Acc | Mean Black Acc | Mean Error Weight (dW>=15) | Mean Quiet Weight (dW<2) | Weight Discrimination Ratio | Pre-Blunder Spillover | Post-Blunder Spillover |',
    );
    sb.writeln('|---|---:|---:|---:|---:|---:|---:|---:|');
    for (final align in core.WindowAlignment.values) {
      final st = alignmentStats[align];
      if (st == null) continue;
      sb.writeln(
        '| ${align.name} | ${st.meanCompositeWhite.toStringAsFixed(2)}% | '
        '${st.meanCompositeBlack.toStringAsFixed(2)}% | '
        '${st.meanErrorMoveWeight.toStringAsFixed(3)} | '
        '${st.meanQuietMoveWeight.toStringAsFixed(3)} | '
        '${st.weightDiscriminationRatio.toStringAsFixed(2)}x | '
        '${st.preBlunderSpilloverWeight.toStringAsFixed(3)} | '
        '${st.postBlunderSpilloverWeight.toStringAsFixed(3)} |',
      );
    }
    sb.writeln();
    sb.writeln('### Per-Game Window Alignment Sensitivity');
    sb.writeln(
      '| Game | k | White (lead / trail / centre) | Black (lead / trail / centre) |',
    );
    sb.writeln('|---|---:|---|---|');
    for (final g in games) {
      final l = g.aggregatesByAlignment[core.WindowAlignment.leading]!;
      final t = g.aggregatesByAlignment[core.WindowAlignment.trailing]!;
      final c = g.aggregatesByAlignment[core.WindowAlignment.centred]!;
      sb.writeln(
        '| ${g.title} | ${c.windowSizeK} | '
        '${l.white.compositeAccuracy.toStringAsFixed(2)}% / '
        '${t.white.compositeAccuracy.toStringAsFixed(2)}% / '
        '${c.white.compositeAccuracy.toStringAsFixed(2)}% | '
        '${l.black.compositeAccuracy.toStringAsFixed(2)}% / '
        '${t.black.compositeAccuracy.toStringAsFixed(2)}% / '
        '${c.black.compositeAccuracy.toStringAsFixed(2)}% |',
      );
    }
    return sb.toString();
  }
}

/// Evaluates identical games through both the legacy and new [chess_review_core]
/// classifiers under identical Stockfish configurations and `>= 500k` node budgets.
class ClassifierComparisonService {
  final EngineService engine;
  final List<Map<String, dynamic>> openingBookEntries;

  ClassifierComparisonService({
    required this.engine,
    required this.openingBookEntries,
  });

  Future<ClassifierComparisonReport> compareGames(
    List<ComparisonGameInput> inputs, {
    core.EngineBudget budget = const core.EngineBudget(
      nodes: 500000,
      threads: 1,
      hashMb: 16,
    ),
    String classificationPresetId = 'lichess',
    core.WindowAlignment primaryNewAlignment = core.WindowAlignment.centred,
  }) async {
    if (budget.nodes < 500000) {
      throw ArgumentError(
        'Phase 5 comparison requires fixed nodes >= 500000 (got ${budget.nodes}).',
      );
    }

    final baseCoreEngine = engine is core.EngineServicePort
        ? engine as core.EngineServicePort
        : EngineServiceToCoreAdapter(engine, presetId: 'comparison');

    final healthy = await baseCoreEngine.checkHealth();
    if (!healthy) {
      throw StateError(
        'Comparison requires a healthy real Stockfish engine (checkHealth failed).',
      );
    }

    // Shared cache across BOTH pipelines guarantees identical Stockfish 500k evaluations.
    final sharedEngine = _DeterministicComparisonEngine(
      inner: baseCoreEngine,
      fixedNodes: budget.nodes,
    );

    final gameResults = <GameComparisonResult>[];
    final matrix = <MoveClassification, Map<MoveClassification, int>>{
      for (final oldL in MoveClassification.values)
        oldL: {for (final newL in MoveClassification.values) newL: 0},
    };
    final oldDist = <MoveClassification, int>{
      for (final l in MoveClassification.values) l: 0,
    };
    final newDist = <MoveClassification, int>{
      for (final l in MoveClassification.values) l: 0,
    };
    final categoryCounts = <String, int>{};
    final sampleDisagreements = <PlyDisagreement>[];

    var totalPlies = 0;
    var exactMatches = 0;

    for (final input in inputs) {
      await sharedEngine.newGame();

      // Run 1: Legacy classifier using identical deterministic Stockfish 500k cache
      final oldRun = await _runSinglePipeline(
        input: input,
        sharedEngine: sharedEngine,
        budget: budget,
        classificationPresetId: classificationPresetId,
        useNewClassifier: false,
      );

      // Run 2: New chess_review_core classifier using same deterministic cache
      final newRun = await _runSinglePipeline(
        input: input,
        sharedEngine: sharedEngine,
        budget: budget,
        classificationPresetId: classificationPresetId,
        useNewClassifier: true,
        alignment: primaryNewAlignment,
      );

      final coreReview = newRun.coreReview!;
      final alignMap = <core.WindowAlignment, core.GameAggregates>{
        for (final align in core.WindowAlignment.values)
          align: core.Aggregates.compute(
            coreReview,
            config: core.ClassificationConfig(windowAlignment: align),
          ),
      };

      final oldMissed = _countLegacyMissedPunishments(oldRun.plies);
      final newMissed = coreReview.plies.where((p) => p.missedPunishment).length;

      final gameDisagreements = <PlyDisagreement>[];
      final nPlies = math.min(oldRun.plies.length, newRun.plies.length);
      for (var i = 0; i < nPlies; i++) {
        final o = oldRun.plies[i];
        final n = newRun.plies[i];
        final corePly = coreReview.plies[i];

        oldDist[o.label] = (oldDist[o.label] ?? 0) + 1;
        newDist[n.label] = (newDist[n.label] ?? 0) + 1;
        matrix[o.label]![n.label] = (matrix[o.label]![n.label] ?? 0) + 1;
        totalPlies++;

        if (o.label == n.label) {
          exactMatches++;
        } else {
          final reason = _diagnoseDisagreement(
            oldPly: o,
            newPly: n,
            corePly: corePly,
          );
          categoryCounts[reason] = (categoryCounts[reason] ?? 0) + 1;
          final d = PlyDisagreement(
            gameTitle: input.title,
            ply: o.ply,
            side: o.ply.isOdd ? 'White' : 'Black',
            moveSan: oldRun.positions[o.ply].moveSan ?? corePly.playedMoveUci,
            oldLabel: o.label,
            newLabel: n.label,
            deltaW: n.deltaW,
            oldWinBefore: o.winBefore,
            newWinBefore: n.winBefore,
            reasonCategory: reason,
          );
          gameDisagreements.add(d);
          if (sampleDisagreements.length < 40) {
            sampleDisagreements.add(d);
          }
        }
      }

      gameResults.add(
        GameComparisonResult(
          gameId: oldRun.gameId,
          title: input.title,
          pliesCount: nPlies,
          oldSummary: oldRun.summary,
          newSummary: newRun.summary,
          oldMissedPunishments: oldMissed,
          newMissedPunishments: newMissed,
          oldPlies: oldRun.plies,
          newPlies: newRun.plies,
          coreReview: coreReview,
          aggregatesByAlignment: alignMap,
          disagreements: gameDisagreements,
        ),
      );
    }

    final alignmentStats = _computeAlignmentStats(gameResults);

    return ClassifierComparisonReport(
      engineVersion: baseCoreEngine.engineVersion,
      budget: budget,
      games: gameResults,
      totalPlies: totalPlies,
      exactMatchPlies: exactMatches,
      confusionMatrix: matrix,
      oldDistribution: oldDist,
      newDistribution: newDist,
      discrepancyCategoryCounts: categoryCounts,
      sampleDisagreements: sampleDisagreements,
      alignmentStats: alignmentStats,
    );
  }

  Future<
      ({
        String gameId,
        List<PositionEntity> positions,
        List<MoveAnalysisEntity> plies,
        GameSummaryEntity summary,
        core.GameReviewResult? coreReview,
      })> _runSinglePipeline({
    required ComparisonGameInput input,
    required _DeterministicComparisonEngine sharedEngine,
    required core.EngineBudget budget,
    required String classificationPresetId,
    required bool useNewClassifier,
    core.WindowAlignment alignment = core.WindowAlignment.centred,
  }) async {
    final storage = StorageRepository();
    storage.setSetting('classification_preset_id', classificationPresetId);
    storage.setSetting('use_new_classifier', useNewClassifier.toString());
    final bookAdapter = OpeningBookAdapter.fromEntries(
      openingBookEntries,
      mirrorToStorage: storage,
    );

    final report = PgnParser.parseMultiGamePgn(input.pgn, source: 'pgn');
    if (report.games.isEmpty) {
      throw StateError('Failed to parse comparison PGN for "${input.title}"');
    }
    final parsed = report.games.single;
    storage.upsertParsedGame(parsed);
    final gameId = parsed.game.id;
    final positions = storage.getPositions(gameId);

    final preset = EnginePresetConfig(
      id: 'fixed_${budget.nodes}',
      displayName: 'Deterministic ${budget.nodes} nodes',
      threads: budget.threads,
      hashMb: budget.hashMb,
      moveTimeMs: 400,
      targetDepth: 16,
      defaultMultiPv: 1,
      fixedNodes: budget.nodes,
    );
    final legacyConfig = ClassificationConfig.byId(classificationPresetId);

    final ExecutedGameReview executed;
    if (useNewClassifier) {
      executed = (await GameReviewRunner.runNewCore(
        gameId: gameId,
        positions: positions,
        storage: storage,
        engine: sharedEngine,
        enginePreset: preset,
        legacyConfig: legacyConfig,
        openingBook: bookAdapter,
        coreConfigOverride: GameReviewRunner.resolveCoreConfig(
          classificationPresetId,
          base: core.ClassificationConfig(windowAlignment: alignment),
        ),
        coreBudgetOverride: budget,
      ))!;
    } else {
      executed = (await GameReviewRunner.runLegacy(
        gameId: gameId,
        positions: positions,
        storage: storage,
        engine: sharedEngine,
        enginePreset: preset,
        classConfig: legacyConfig,
      ))!;
    }

    return (
      gameId: gameId,
      positions: positions,
      plies: executed.moveAnalyses,
      summary: executed.summary,
      coreReview: executed.coreReview,
    );
  }

  static int _countLegacyMissedPunishments(List<MoveAnalysisEntity> plies) {
    var missed = 0;
    for (var i = 0; i < plies.length - 1; i++) {
      final oppMove = plies[i];
      if (oppMove.deltaW >= 20.0) {
        final reply = plies[i + 1];
        if (reply.deltaW > 0.30 * oppMove.deltaW) {
          missed++;
        }
      }
    }
    return missed;
  }

  static String _diagnoseDisagreement({
    required MoveAnalysisEntity oldPly,
    required MoveAnalysisEntity newPly,
    required core.MoveClassificationResult corePly,
  }) {
    if (corePly.isForced && oldPly.label != MoveClassification.best) {
      return 'Forced move correction (Old ${oldPly.label.label} -> New Best)';
    }
    if (oldPly.label == MoveClassification.best &&
        newPly.label == MoveClassification.excellent &&
        !corePly.isEngineTopMove &&
        corePly.deltaW < 1.0) {
      return 'Non-top move <1 dW (Old Best -> New Excellent)';
    }
    if (oldPly.label == MoveClassification.brilliant &&
        newPly.label != MoveClassification.brilliant) {
      return 'Old unsustainable/unconfirmed sacrifice filtered (Old Brilliant -> New ${newPly.label.label})';
    }
    if (oldPly.label == MoveClassification.great &&
        newPly.label != MoveClassification.great) {
      return 'Old turnsOrSavesGame inflated Great removed (Old Great -> New ${newPly.label.label})';
    }
    if (newPly.label == MoveClassification.great &&
        oldPly.label != MoveClassification.great) {
      return 'Strict only-move gap>=15 Great detected (Old ${oldPly.label.label} -> New Great)';
    }
    if (oldPly.isBook != newPly.isBook) {
      return 'Book EPD / maxBookPly boundary (Old ${oldPly.label.label} -> New ${newPly.label.label})';
    }
    if (corePly.winBefore <= 5.0 &&
        (newPly.label == MoveClassification.mistake ||
            newPly.label == MoveClassification.blunder) &&
        oldPly.label != newPly.label) {
      return 'Saturation guard cpLoss check (Old ${oldPly.label.label} -> New ${newPly.label.label})';
    }
    return 'Other rule threshold difference (Old ${oldPly.label.label} -> New ${newPly.label.label})';
  }

  static Map<core.WindowAlignment, AlignmentEmpiricalStats>
      _computeAlignmentStats(List<GameComparisonResult> games) {
    final result = <core.WindowAlignment, AlignmentEmpiricalStats>{};
    for (final align in core.WindowAlignment.values) {
      var whiteSum = 0.0;
      var blackSum = 0.0;
      var errWeightSum = 0.0;
      var errCount = 0;
      var quietWeightSum = 0.0;
      var quietCount = 0;
      var preSpillSum = 0.0;
      var preSpillCount = 0;
      var postSpillSum = 0.0;
      var postSpillCount = 0;

      for (final g in games) {
        final agg = g.aggregatesByAlignment[align]!;
        whiteSum += agg.white.compositeAccuracy;
        blackSum += agg.black.compositeAccuracy;

        final plies = g.coreReview.plies;
        final weights = agg.perMoveWeights;
        for (var i = 0; i < plies.length; i++) {
          final dw = plies[i].deltaW;
          final w = weights[i];
          if (dw >= 15.0) {
            errWeightSum += w;
            errCount++;
          } else if (dw < 2.0) {
            quietWeightSum += w;
            quietCount++;
          }

          // Measure spillover onto quiet moves immediately before vs after a sharp blunder (dW >= 20)
          if (dw < 2.0 && i + 1 < plies.length && plies[i + 1].deltaW >= 20.0) {
            preSpillSum += w;
            preSpillCount++;
          }
          if (dw < 2.0 && i - 1 >= 0 && plies[i - 1].deltaW >= 20.0) {
            postSpillSum += w;
            postSpillCount++;
          }
        }
      }

      final nGames = games.isEmpty ? 1 : games.length;
      final meanErrW = errCount == 0 ? 0.0 : errWeightSum / errCount;
      final meanQuietW = quietCount == 0 ? 0.0 : quietWeightSum / quietCount;
      final ratio = meanQuietW > 0 ? meanErrW / meanQuietW : 0.0;

      result[align] = AlignmentEmpiricalStats(
        alignment: align,
        meanCompositeWhite: whiteSum / nGames,
        meanCompositeBlack: blackSum / nGames,
        meanErrorMoveWeight: meanErrW,
        meanQuietMoveWeight: meanQuietW,
        weightDiscriminationRatio: ratio,
        preBlunderSpilloverWeight:
            preSpillCount == 0 ? 0.0 : preSpillSum / preSpillCount,
        postBlunderSpilloverWeight:
            postSpillCount == 0 ? 0.0 : postSpillSum / postSpillCount,
        errorMovesCount: errCount,
        quietMovesCount: quietCount,
      );
    }
    return result;
  }
}

/// Deterministic wrapper sharing Stockfish 19 fixed-node evaluations identically
/// between legacy [EngineService] and new [core.EngineServicePort].
class _DeterministicComparisonEngine
    implements EngineService, core.EngineServicePort {
  final core.EngineServicePort inner;
  final int fixedNodes;
  final Map<String, core.EngineAnalysisResult> _cache = {};

  _DeterministicComparisonEngine({
    required this.inner,
    required this.fixedNodes,
  });

  @override
  String get engineVersion => inner.engineVersion;

  @override
  bool get isFallbackEngine => false;

  @override
  bool get isThermalThrottled => false;

  @override
  void setThermalThrottle(bool throttled) {}

  @override
  Future<void> init() async {}

  @override
  Future<bool> checkHealth() => inner.checkHealth();

  @override
  Future<void> newGame() => inner.newGame();

  @override
  Future<core.EngineAnalysisResult> analyse(
    String fen, {
    int multiPv = 1,
    required core.EngineBudget budget,
  }) async {
    final norm = core.EngineAnalysisResult.normalizeFen(fen);
    final effectiveBudget = core.EngineBudget(
      nodes: fixedNodes,
      threads: budget.threads,
      hashMb: budget.hashMb,
    );
    final key = core.EngineAnalysisResult.computeCacheKey(
      normalizedFen: norm,
      engineVersion: engineVersion,
      budget: effectiveBudget,
      multiPv: multiPv,
    );
    final hit = _cache[key];
    if (hit != null) return hit;

    final res = await inner.analyse(
      norm,
      multiPv: multiPv,
      budget: effectiveBudget,
    );
    _cache[key] = res;
    return res;
  }

  @override
  Future<EngineEvalEntity> evaluatePosition(
    String fen,
    EnginePresetConfig preset, {
    int multiPv = 1,
  }) async {
    final board = ch.Chess.fromFEN(fen);
    if (board.generate_moves().isEmpty) {
      final isMate = board.in_check;
      return EngineEvalEntity(
        positionKey: fen,
        cp: isMate ? null : 0,
        mate: isMate ? -1 : null,
        depth: preset.targetDepth,
        nodes: 0,
        pvUci: const [],
        multipv: const [],
        createdAt: DateTime.now().millisecondsSinceEpoch,
        isReliable: true,
      );
    }

    final budget = core.EngineBudget(
      nodes: fixedNodes,
      threads: 1,
      hashMb: 16,
    );
    final coreRes = await analyse(fen, multiPv: multiPv, budget: budget);
    final top = coreRes.topLine;
    return EngineEvalEntity(
      positionKey: fen,
      cp: top?.mate != null ? null : top?.cp,
      mate: top?.mate,
      depth: 16,
      nodes: coreRes.nodes,
      pvUci: top?.pv ?? const [],
      multipv: coreRes.lines
          .map(
            (l) => <String, dynamic>{
              'uci': l.moveUci,
              'cp': l.cp,
              'mate': l.mate,
              'pv': l.pv,
            },
          )
          .toList(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      isReliable: true,
    );
  }

  @override
  Future<void> dispose() => inner.dispose();
}
