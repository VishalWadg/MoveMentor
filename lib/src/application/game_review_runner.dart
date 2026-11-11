import 'dart:convert';
import 'package:chess/chess.dart' as ch;
import 'package:chess_review_core/chess_review_core.dart' as core;
import 'package:crypto/crypto.dart';
import '../adapters/engine/stockfish_engine_adapter.dart';
import '../adapters/storage/opening_book_adapter.dart';
import '../adapters/storage/sqlite_storage_adapter.dart';
import '../domain/analysis/move_classifier.dart';
import '../domain/analysis/phase_detector.dart';
import '../domain/analysis/win_accuracy_calculator.dart';
import '../domain/chess/chess_models.dart';
import '../domain/chess/fen_normalizer.dart';
import '../domain/chess/see_evaluator.dart';
import '../domain/coach/coach_contracts.dart';
import '../ports/ports.dart';

/// Output bundle of Stage 2-3 game evaluation & move classification.
class ExecutedGameReview {
  final List<MoveAnalysisEntity> moveAnalyses;
  final GameSummaryEntity summary;
  final Map<int, EngineEvalEntity> evalsByPly;
  final core.GameReviewResult? coreReview;
  final core.GameAggregates? coreAggregates;

  const ExecutedGameReview({
    required this.moveAnalyses,
    required this.summary,
    required this.evalsByPly,
    this.coreReview,
    this.coreAggregates,
  });
}

/// Pure-Dart (non-Flutter) orchestrator for executing Stage 2-3 analysis via
/// either the preserved legacy classifier or [chess_review_core].
///
/// Reused by both [AnalysisPipelineService] (Flutter runtime) and
/// [ClassifierComparisonService] / CLI benchmark tools.
abstract final class GameReviewRunner {
  static Future<ExecutedGameReview?> runNewCore({
    required String gameId,
    required List<PositionEntity> positions,
    required StorageRepository storage,
    required EngineService engine,
    required EnginePresetConfig enginePreset,
    required ClassificationConfig legacyConfig,
    core.OpeningBookPort? openingBook,
    core.ClassificationConfig? coreConfigOverride,
    core.EngineBudget? coreBudgetOverride,
    CancelToken? cancel,
    void Function(int completedCount, int totalPlies)? onProgress,
  }) async {
    await _ensureEngineInitialized(engine);

    final totalPlies = positions.length - 1;
    final coreConfig =
        coreConfigOverride ?? resolveCoreConfig(legacyConfig.presetId);
    final coreBudget =
        coreBudgetOverride ?? resolveCoreBudget(enginePreset);

    final engineIsReliable = !engine.isFallbackEngine;
    final core.EngineServicePort baseCoreEngine;
    if (engine is StockfishEngineAdapter && engine.isFallbackEngine) {
      if (engine.refuseSilentFallback) {
        throw StateError(
          'Real Stockfish engine is unavailable (checkHealth=${engine.isHealthy}). '
          'Silent fallback to 2-ply minimax is refused.',
        );
      }
      baseCoreEngine = EngineServiceToCoreAdapter(
        engine,
        presetId: enginePreset.id,
        allowUnreliableFallback: true,
      );
    } else {
      baseCoreEngine = engine is core.EngineServicePort
          ? engine as core.EngineServicePort
          : EngineServiceToCoreAdapter(engine, presetId: enginePreset.id);
    }

    final evalByNormFen = <String, core.EngineAnalysisResult>{};
    var evaluatedCount = 0;

    final cachedEngine = _StorageBackedCoreEnginePort(
      inner: baseCoreEngine,
      storage: storage,
      cancel: cancel,
      isReliable: engineIsReliable,
      onPositionEvaluated: (normFen, res) {
        evalByNormFen[normFen] = res;
        evaluatedCount++;
        onProgress?.call(evaluatedCount.clamp(0, totalPlies), totalPlies);
      },
    );

    final resolvedBook = openingBook ?? OpeningBookAdapter.fromStorage(storage);
    final movesUci = positions
        .skip(1)
        .map((p) => (p.moveUci ?? '').toLowerCase())
        .where((u) => u.isNotEmpty)
        .toList();

    final review = await core.GameReviewer(
      engine: cachedEngine,
      openingBook: resolvedBook,
      classifier: core.Classifier(config: coreConfig),
    ).reviewGame(
      initialFen: positions.first.fen,
      movesUci: movesUci,
      budget: coreBudget,
    );

    if (cancel?.isCancelled == true) {
      return null;
    }

    final aggregates = core.Aggregates.compute(review, config: coreConfig);
    final evalsByPly = <int, EngineEvalEntity>{};

    for (var i = 0; i < positions.length; i++) {
      final pos = positions[i];
      final normFen = core.EngineAnalysisResult.normalizeFen(pos.fen);
      final coreRes = evalByNormFen[normFen];
      evalsByPly[pos.ply] = coreRes != null
          ? toEvalEntity(
              pos.positionKey,
              coreRes,
              enginePreset.targetDepth,
              isReliable: engineIsReliable,
            )
          : EngineEvalEntity(
              positionKey: pos.positionKey,
              cp: 0,
              mate: null,
              depth: enginePreset.targetDepth,
              nodes: 0,
              pvUci: const [],
              multipv: const [],
              createdAt: DateTime.now().millisecondsSinceEpoch,
              isReliable: engineIsReliable,
            );
    }

    final moveAnalyses = <MoveAnalysisEntity>[];
    for (var idx = 0; idx < review.plies.length; idx++) {
      final plyNum = idx + 1;
      final posBefore = positions[plyNum - 1];
      final res = review.plies[idx];
      final label = mapCoreLabel(res.label);
      final phase = mapCorePhase(res.phase);
      final bestMoveUci =
          evalsByPly[plyNum - 1]!.pvUci.firstOrNull ?? res.playedMoveUci;
      final bestSan = uciToSan(posBefore.fen, bestMoveUci) ??
          (positions[plyNum].moveSan ?? '');
      final vol = idx < aggregates.perMoveWeights.length
          ? aggregates.perMoveWeights[idx]
          : 1.0;

      final item = MoveAnalysisEntity(
        gameId: gameId,
        ply: plyNum,
        winBefore: res.winBefore,
        winAfter: res.winAfter,
        deltaW: res.deltaW,
        accuracy: res.accuracy,
        label: label,
        isBook: res.isBook,
        isSacrifice: res.isSacrifice,
        bestMoveUci: bestMoveUci,
        bestMoveSan: bestSan,
        secondBestDeltaW: res.secondBestDeltaW,
        volatility: vol,
        phase: phase,
        presetId: legacyConfig.presetId,
      );
      storage.saveMoveAnalysis(item);
      moveAnalyses.add(item);
    }

    final labelCounts = <String, Map<String, int>>{
      'white': {
        for (final e in aggregates.white.labelCounts.entries)
          mapCoreLabel(e.key).label: e.value,
      },
      'black': {
        for (final e in aggregates.black.labelCounts.entries)
          mapCoreLabel(e.key).label: e.value,
      },
    };

    final summary = GameSummaryEntity(
      gameId: gameId,
      accWhite: aggregates.white.compositeAccuracy,
      accBlack: aggregates.black.compositeAccuracy,
      acplWhite: aggregates.white.acpl,
      acplBlack: aggregates.black.acpl,
      phaseAccuracy: {
        'white': {
          for (final entry in aggregates.white.phaseAccuracies.entries)
            mapCorePhase(entry.key).label: entry.value,
        },
        'black': {
          for (final entry in aggregates.black.phaseAccuracies.entries)
            mapCorePhase(entry.key).label: entry.value,
        },
      },
      counts: labelCounts,
      presetId: legacyConfig.presetId,
      engineVersion: baseCoreEngine.engineVersion,
    );

    return ExecutedGameReview(
      moveAnalyses: moveAnalyses,
      summary: summary,
      evalsByPly: evalsByPly,
      coreReview: review,
      coreAggregates: aggregates,
    );
  }

  static Future<ExecutedGameReview?> runLegacy({
    required String gameId,
    required List<PositionEntity> positions,
    required StorageRepository storage,
    required EngineService engine,
    required EnginePresetConfig enginePreset,
    required ClassificationConfig classConfig,
    CancelToken? cancel,
    void Function(int currentPly, int totalPlies)? onEvaluatingPly,
  }) async {
    await _ensureEngineInitialized(engine);

    final totalPlies = positions.length - 1;
    final evalsByPly = <int, EngineEvalEntity>{};

    for (var i = 0; i < positions.length; i++) {
      if (cancel?.isCancelled == true) {
        return null;
      }

      final pos = positions[i];
      var cached = storage.getEngineEval(pos.positionKey);
      if (cached == null) {
        final rawEval = await engine.evaluatePosition(
          pos.fen,
          enginePreset,
          multiPv: enginePreset.defaultMultiPv,
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
          isReliable: rawEval.isReliable,
        );
        storage.saveEngineEval(cached);
      }
      evalsByPly[pos.ply] = cached;
      onEvaluatingPly?.call(i, totalPlies);
    }

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
        final mpv2Eval = await engine.evaluatePosition(
          posBefore.fen,
          enginePreset,
          multiPv: 2,
        );
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
      final destSq = extractDestSq(moveSan);
      final isRecapture = moveSan.contains('x') && prevCaptureSquare == destSq;
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
      final mateAfterForMover = evalAfter.mate != null ? -evalAfter.mate! : null;

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
      final bestSan = uciToSan(posBefore.fen, bestMoveUci) ?? moveSan;

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
            list.isEmpty ? 100.0 : list.reduce((a, b) => a + b) / list.length,
          ),
        ),
        'black': phaseAccs['black']!.map(
          (k, list) => MapEntry(
            k,
            list.isEmpty ? 100.0 : list.reduce((a, b) => a + b) / list.length,
          ),
        ),
      },
      counts: labelCounts,
      presetId: classConfig.presetId,
      engineVersion: engine.engineVersion,
    );

    return ExecutedGameReview(
      moveAnalyses: moveAnalyses,
      summary: summary,
      evalsByPly: evalsByPly,
    );
  }

  static core.ClassificationConfig resolveCoreConfig(
    String classPresetId, {
    core.ClassificationConfig? base,
  }) {
    final fallback = base ?? core.ClassificationConfig.standard;
    final core.ClassificationBands bands;
    switch (classPresetId) {
      case 'pdf':
      case 'chesscom':
        bands = core.ClassificationBands.chesscomStyle;
        break;
      case 'wintr':
        bands = core.ClassificationBands.wintrStyle;
        break;
      default:
        bands = fallback.bands;
        break;
    }
    return core.ClassificationConfig(
      bands: bands,
      accuracyBonus: fallback.accuracyBonus,
      countBookInAccuracy: fallback.countBookInAccuracy,
      turnsTheGameVariant: fallback.turnsTheGameVariant,
      windowAlignment: fallback.windowAlignment,
      harmonicEpsilon: fallback.harmonicEpsilon,
    );
  }

  static core.EngineBudget resolveCoreBudget(
    EnginePresetConfig preset, {
    core.EngineBudget? override,
  }) {
    if (override != null) return override;
    final int nodes;
    if (preset.fixedNodes != null) {
      nodes = preset.fixedNodes!;
    } else if (preset.id == 'fast') {
      nodes = 100000;
    } else if (preset.id == 'deep') {
      nodes = 1500000;
    } else {
      nodes = 500000;
    }
    return core.EngineBudget(
      nodes: nodes,
      threads: preset.threads,
      hashMb: preset.hashMb,
    );
  }

  static MoveClassification mapCoreLabel(core.ClassificationLabel label) {
    switch (label) {
      case core.ClassificationLabel.book:
        return MoveClassification.book;
      case core.ClassificationLabel.brilliant:
        return MoveClassification.brilliant;
      case core.ClassificationLabel.great:
        return MoveClassification.great;
      case core.ClassificationLabel.best:
        return MoveClassification.best;
      case core.ClassificationLabel.excellent:
        return MoveClassification.excellent;
      case core.ClassificationLabel.good:
        return MoveClassification.good;
      case core.ClassificationLabel.inaccuracy:
        return MoveClassification.inaccuracy;
      case core.ClassificationLabel.mistake:
        return MoveClassification.mistake;
      case core.ClassificationLabel.blunder:
        return MoveClassification.blunder;
    }
  }

  static GamePhase mapCorePhase(core.GamePhase? phase) {
    switch (phase) {
      case core.GamePhase.opening:
        return GamePhase.opening;
      case core.GamePhase.endgame:
        return GamePhase.endgame;
      case core.GamePhase.middlegame:
      case null:
        return GamePhase.middlegame;
    }
  }

  static Future<void> _ensureEngineInitialized(EngineService engine) async {
    if (engine is StockfishEngineAdapter &&
        !engine.isHealthy &&
        !engine.isDisposed &&
        engine.customStockfishBinaryPath != null &&
        engine.customStockfishBinaryPath!.isNotEmpty) {
      await engine.init();
    }
  }

  static EngineEvalEntity toEvalEntity(
    String cacheKey,
    core.EngineAnalysisResult res,
    int fallbackDepth, {
    bool isReliable = true,
  }) {
    final top = res.topLine;
    return EngineEvalEntity(
      positionKey: cacheKey,
      cp: top?.mate != null ? null : top?.cp,
      mate: top?.mate,
      depth: fallbackDepth,
      nodes: res.nodes,
      pvUci: top?.pv ?? const [],
      multipv: res.lines
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
      isReliable: isReliable,
    );
  }

  static String extractDestSq(String san) {
    final m = RegExp(r'([a-h][1-8])').allMatches(san);
    return m.isNotEmpty ? m.last.group(1)! : 'e4';
  }

  static String? uciToSan(String fen, String? uci) {
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
}

class _StorageBackedCoreEnginePort implements core.EngineServicePort {
  final core.EngineServicePort inner;
  final StorageRepository storage;
  final CancelToken? cancel;
  final bool isReliable;
  final void Function(String normFen, core.EngineAnalysisResult res)
      onPositionEvaluated;

  _StorageBackedCoreEnginePort({
    required this.inner,
    required this.storage,
    required this.cancel,
    required this.isReliable,
    required this.onPositionEvaluated,
  });

  @override
  String get engineVersion => inner.engineVersion;

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
    if (cancel?.isCancelled == true) {
      throw const EngineCancelledException();
    }

    final normFen = core.EngineAnalysisResult.normalizeFen(fen);
    final rawKey = core.EngineAnalysisResult.computeCacheKey(
      normalizedFen: normFen,
      engineVersion: engineVersion,
      budget: budget,
      multiPv: multiPv,
    );
    final cacheKey = sha1.convert(utf8.encode(rawKey)).toString();
    final cached = storage.getEngineEval(cacheKey);
    if (cached != null && (!isReliable || cached.isReliable)) {
      final restored = _fromEvalEntity(normFen, engineVersion, budget, cached);
      onPositionEvaluated(normFen, restored);
      return restored;
    }

    final core.EngineAnalysisResult res;
    if (inner is StockfishEngineAdapter) {
      res = await (inner as StockfishEngineAdapter).analyse(
        fen,
        multiPv: multiPv,
        budget: budget,
        cancel: cancel,
      );
    } else {
      res = await inner.analyse(fen, multiPv: multiPv, budget: budget);
    }

    storage.saveEngineEval(
      GameReviewRunner.toEvalEntity(
        cacheKey,
        res,
        16,
        isReliable: isReliable,
      ),
    );
    onPositionEvaluated(normFen, res);
    return res;
  }

  @override
  Future<void> dispose() => inner.dispose();

  static core.EngineAnalysisResult _fromEvalEntity(
    String normFen,
    String engineVersion,
    core.EngineBudget budget,
    EngineEvalEntity entity,
  ) {
    final lines = <core.EnginePvLine>[];
    if (entity.multipv.isNotEmpty) {
      for (var i = 0; i < entity.multipv.length; i++) {
        final m = entity.multipv[i];
        final pv = (m['pv'] as List<dynamic>?)?.cast<String>() ??
            (m['uci'] != null ? <String>[m['uci'] as String] : const <String>[]);
        if (pv.isEmpty) continue;
        final cp = m['cp'] as int?;
        final mate = m['mate'] as int?;
        lines.add(
          core.EnginePvLine(
            multiPvRank: i + 1,
            cp: cp,
            mate: mate,
            winPercent: core.WinPercent.fromScore(cp: cp, mate: mate),
            moveUci: pv.first,
            pv: pv,
          ),
        );
      }
    } else if (entity.pvUci.isNotEmpty) {
      lines.add(
        core.EnginePvLine(
          multiPvRank: 1,
          cp: entity.cp,
          mate: entity.mate,
          winPercent: core.WinPercent.fromScore(cp: entity.cp, mate: entity.mate),
          moveUci: entity.pvUci.first,
          pv: entity.pvUci,
        ),
      );
    }
    return core.EngineAnalysisResult(
      fen: normFen,
      engineVersion: engineVersion,
      budget: budget,
      lines: lines,
      nodes: entity.nodes,
    );
  }
}
