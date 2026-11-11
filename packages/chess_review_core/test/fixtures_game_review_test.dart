import 'dart:convert';
import 'dart:io';
import 'package:chess/chess.dart' as ch;
import 'package:test/test.dart';
import 'package:chess_review_core/chess_review_core.dart';

File _resolvePath(String relativeFromRoot, String relativeFromPackage) {
  final f1 = File(relativeFromPackage);
  if (f1.existsSync()) return f1;
  final f2 = File(relativeFromRoot);
  if (f2.existsSync()) return f2;
  throw StateError('File not found: $relativeFromPackage / $relativeFromRoot');
}

class JsonOpeningBook extends OpeningBookPort {
  final Map<String, OpeningEntry> _byEpd;

  JsonOpeningBook._(this._byEpd);

  factory JsonOpeningBook.fromDefaultAsset() {
    final file = _resolvePath(
      'assets/openings/eco_openings.json',
      '../../assets/openings/eco_openings.json',
    );
    final raw = jsonDecode(file.readAsStringSync()) as List<dynamic>;
    final map = <String, OpeningEntry>{};
    for (final item in raw) {
      final m = item as Map<String, dynamic>;
      final epd = m['epd'] as String;
      map[epd] = OpeningEntry(
        eco: m['eco'] as String,
        name: m['name'] as String,
        epd: epd,
      );
    }
    return JsonOpeningBook._(map);
  }

  @override
  OpeningEntry? lookupByEpd(String epd) => _byEpd[epd];
}

class FixtureEngineService implements EngineServicePort {
  final String _engineVersion;
  final Map<String, Map<String, dynamic>> _exactPositions;
  final Map<String, Map<String, dynamic>> _noEpPositions;
  final List<({String fen, int multiPv})> recordedCalls = [];
  int newGameCalls = 0;

  FixtureEngineService._(
    this._engineVersion,
    this._exactPositions,
    this._noEpPositions,
  );

  factory FixtureEngineService.fromFixtureJson(Map<String, dynamic> json) {
    final engineMeta = json['engine'] as Map<String, dynamic>;
    final version = '${engineMeta['idName']} (${engineMeta['net'] ?? 'nnue'})';
    final rawPositions = json['positions'] as Map<String, dynamic>;
    final exact = <String, Map<String, dynamic>>{};
    final noEp = <String, Map<String, dynamic>>{};
    for (final entry in rawPositions.entries) {
      final norm = EngineAnalysisResult.normalizeFen(entry.key);
      final val = entry.value as Map<String, dynamic>;
      exact[norm] = val;
      noEp[_stripEp(norm)] = val;
    }
    return FixtureEngineService._(version, exact, noEp);
  }

  static String _stripEp(String normalizedFen) {
    final parts = normalizedFen.split(' ');
    if (parts.length < 6) return normalizedFen;
    return '${parts[0]} ${parts[1]} ${parts[2]} ${parts[4]} ${parts[5]}';
  }

  @override
  String get engineVersion => _engineVersion;

  @override
  Future<bool> checkHealth() async => true;

  @override
  Future<void> newGame() async {
    newGameCalls++;
  }

  @override
  Future<EngineAnalysisResult> analyse(
    String fen, {
    int multiPv = 1,
    required EngineBudget budget,
  }) async {
    final norm = EngineAnalysisResult.normalizeFen(fen);
    recordedCalls.add((fen: norm, multiPv: multiPv));

    final record = _exactPositions[norm] ?? _noEpPositions[_stripEp(norm)];
    if (record == null) {
      throw StateError(
        'Fixture missing recorded engine position for FEN: $norm',
      );
    }

    final key = multiPv <= 1 ? 'multiPv1' : 'multiPv$multiPv';
    final rawAnalysis = record[key] as Map<String, dynamic>?;
    if (rawAnalysis == null) {
      throw StateError('Fixture missing $key for FEN: $norm');
    }

    final rawLines = rawAnalysis['lines'] as List<dynamic>;
    final lines = rawLines.map((item) {
      final m = item as Map<String, dynamic>;
      final cp = m['cp'] as int?;
      final mate = m['mate'] as int?;
      final pv = (m['pv'] as List<dynamic>).cast<String>();
      final wp = (m['winPercent'] as num?)?.toDouble() ??
          WinPercent.fromScore(cp: cp, mate: mate);
      return EnginePvLine(
        multiPvRank: m['multiPvRank'] as int,
        cp: cp,
        mate: mate,
        winPercent: wp,
        moveUci: m['moveUci'] as String,
        pv: pv,
      );
    }).toList();

    return EngineAnalysisResult(
      fen: norm,
      engineVersion: _engineVersion,
      budget: budget,
      lines: lines,
      nodes: (rawAnalysis['nodes'] as int?) ?? budget.nodes,
    );
  }

  @override
  Future<void> dispose() async {}
}

Map<String, dynamic> _loadFixture(String filename) {
  final file = _resolvePath(
    'test/fixtures/$filename',
    'test/fixtures/$filename',
  );
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _assertSideAggregateMatches(
  SideAggregate actual,
  Map<String, dynamic> expected, {
  required String context,
}) {
  expect(actual.moveCount, equals(expected['moveCount']), reason: context);
  expect(
    actual.compositeAccuracy,
    closeTo((expected['compositeAccuracy'] as num).toDouble(), 1e-5),
    reason: '$context compositeAccuracy',
  );
  expect(
    actual.volatilityWeightedAccuracy,
    closeTo((expected['volatilityWeightedAccuracy'] as num).toDouble(), 1e-5),
    reason: '$context volatilityWeightedAccuracy',
  );
  expect(
    actual.harmonicAccuracy,
    closeTo((expected['harmonicAccuracy'] as num).toDouble(), 1e-5),
    reason: '$context harmonicAccuracy',
  );
  expect(
    actual.acpl,
    closeTo((expected['acpl'] as num).toDouble(), 1e-5),
    reason: '$context acpl',
  );

  final expectedPhases = expected['phaseAccuracies'] as Map<String, dynamic>;
  expect(
    actual.phaseAccuracies.map((k, v) => MapEntry(k.name, v)).keys.toSet(),
    equals(expectedPhases.keys.toSet()),
    reason: '$context phaseAccuracies keys',
  );
  for (final entry in expectedPhases.entries) {
    final phase = GamePhase.values.firstWhere((p) => p.name == entry.key);
    expect(
      actual.phaseAccuracies[phase],
      closeTo((entry.value as num).toDouble(), 1e-5),
      reason: '$context phase ${entry.key}',
    );
  }
}

void _assertExpectedReviewAndAggregates(
  String filename,
  Map<String, dynamic> fixtureJson,
  GameReviewResult review,
  FixtureEngineService engine,
) {
  final expected = fixtureJson['expected'] as Map<String, dynamic>;
  expect(review.plies.length, equals(expected['pliesCount']), reason: filename);
  expect(
    review.plies.where((p) => p.isBook).length,
    equals(expected['bookPliesCount']),
    reason: '$filename bookPliesCount',
  );

  final forcedPlies = [
    for (var i = 0; i < review.plies.length; i++)
      if (review.plies[i].isForced) i + 1,
  ];
  expect(forcedPlies, equals(expected['forcedPlies']), reason: filename);

  final brilliantPlies = [
    for (var i = 0; i < review.plies.length; i++)
      if (review.plies[i].label == ClassificationLabel.brilliant) i + 1,
  ];
  expect(brilliantPlies, equals(expected['brilliantPlies']), reason: filename);

  final greatPlies = [
    for (var i = 0; i < review.plies.length; i++)
      if (review.plies[i].label == ClassificationLabel.great) i + 1,
  ];
  expect(greatPlies, equals(expected['greatPlies']), reason: filename);

  final missedPlies = [
    for (var i = 0; i < review.plies.length; i++)
      if (review.plies[i].missedPunishment) i + 1,
  ];
  expect(missedPlies, equals(expected['missedPunishmentPlies']), reason: filename);

  final phasesSeen = review.plies.map((p) => p.phase?.name).toList();
  expect(
    phasesSeen.toSet(),
    equals((expected['phasesSeen'] as List<dynamic>).cast<String>().toSet()),
    reason: '$filename phasesSeen',
  );

  final actualLabels = <String, int>{};
  for (final ply in review.plies) {
    actualLabels[ply.label.name] = (actualLabels[ply.label.name] ?? 0) + 1;
  }
  expect(actualLabels, equals(expected['labelCounts']), reason: filename);

  // Zero-sum property across all consecutive plies and no NaN/negative losses.
  for (var i = 0; i < review.plies.length; i++) {
    final ply = review.plies[i];
    expect(ply.accuracy.isNaN, isFalse);
    expect(ply.accuracy, inInclusiveRange(0.0, 100.0));
    expect(ply.cpLoss, greaterThanOrEqualTo(0));
    expect(ply.phase, isNotNull);
    if (ply.isForced) {
      expect(ply.label, equals(ClassificationLabel.best));
      expect(ply.usedMultiPv2, isFalse);
    }
    if (ply.isBook) {
      expect(ply.usedMultiPv2, isFalse);
    }
    if (i < review.plies.length - 1) {
      expect(
        ply.winAfter + review.plies[i + 1].winBefore,
        closeTo(100.0, 1e-9),
        reason: '$filename zero-sum ply ${i + 1} -> ${i + 2}',
      );
    }
  }

  // Verify MultiPV 2 calls were only placed when GameReviewer enabled MultiPV 2.
  final multiPv2CallsCount =
      engine.recordedCalls.where((c) => c.multiPv == 2).length;
  expect(
    multiPv2CallsCount,
    lessThanOrEqualTo(review.plies.where((p) => p.usedMultiPv2).length),
    reason: '$filename extra unrequested MultiPV 2 engine calls',
  );

  // Verify Aggregates for all 3 alignments (leading, trailing, centred).
  final expectedByAlign =
      expected['aggregatesByAlignment'] as Map<String, dynamic>;
  for (final alignment in WindowAlignment.values) {
    final agg = Aggregates.compute(
      review,
      config: ClassificationConfig(windowAlignment: alignment),
    );
    final expAlign = expectedByAlign[alignment.name] as Map<String, dynamic>;
    expect(agg.windowSizeK, equals(expAlign['windowSizeK']));
    expect(agg.positionWinPercentsWhite.length, equals(review.plies.length + 1));
    expect(agg.perMoveWeights.length, equals(review.plies.length));
    for (final w in agg.perMoveWeights) {
      expect(w, inInclusiveRange(0.5, 12.0));
    }
    _assertSideAggregateMatches(
      agg.white,
      expAlign['white'] as Map<String, dynamic>,
      context: '$filename ${alignment.name} White',
    );
    _assertSideAggregateMatches(
      agg.black,
      expAlign['black'] as Map<String, dynamic>,
      context: '$filename ${alignment.name} Black',
    );
  }
}

void main() {
  final openingBook = JsonOpeningBook.fromDefaultAsset();

  group('Test 11: Real Stockfish 19 recorded fixtures replay (GameReviewer + Aggregates)', () {
    test('Fixture 1: Italian Game (39 plies, forced skip, checkmate terminal, full Aggregates)', () async {
      const filename = 'italian_game_500k.json';
      final json = _loadFixture(filename);
      final config = json['config'] as Map<String, dynamic>;
      expect(config['nodes'], equals(500000));
      expect(config['threads'], equals(1));
      expect(config['hashMb'], equals(16));

      final engine = FixtureEngineService.fromFixtureJson(json);
      final budget = EngineBudget(
        nodes: config['nodes'] as int,
        threads: config['threads'] as int,
        hashMb: config['hashMb'] as int,
      );
      final movesUci = (json['movesUci'] as List<dynamic>).cast<String>();
      final initialFen = json['initialFen'] as String;

      final review = await GameReviewer(
        engine: engine,
        openingBook: openingBook,
      ).reviewGame(
        initialFen: initialFen,
        movesUci: movesUci,
        budget: budget,
      );

      expect(engine.newGameCalls, equals(1));
      _assertExpectedReviewAndAggregates(filename, json, review, engine);

      // Checkmate terminal (39. Qf7#) never queries the engine and sets W_after = 100.
      expect(review.plies.last.winAfter, equals(100.0));
      final chess = ch.Chess.fromFEN(initialFen);
      for (final uci in movesUci) {
        chess.move({'from': uci.substring(0, 2), 'to': uci.substring(2, 4)});
      }
      final terminalNorm = EngineAnalysisResult.normalizeFen(chess.fen);
      expect(
        engine.recordedCalls.any((c) => c.fen == terminalNorm),
        isFalse,
      );
    });

    test('Fixture 2: Quiet Petrov Endgame Draw (62 plies, Opening -> Middlegame -> Endgame, threefold draw)', () async {
      const filename = 'quiet_endgame_draw.json';
      final json = _loadFixture(filename);
      final config = json['config'] as Map<String, dynamic>;
      final engine = FixtureEngineService.fromFixtureJson(json);
      final budget = EngineBudget(
        nodes: config['nodes'] as int,
        threads: config['threads'] as int,
        hashMb: config['hashMb'] as int,
      );
      final movesUci = (json['movesUci'] as List<dynamic>).cast<String>();
      final initialFen = json['initialFen'] as String;

      final review = await GameReviewer(
        engine: engine,
        openingBook: openingBook,
      ).reviewGame(
        initialFen: initialFen,
        movesUci: movesUci,
        budget: budget,
      );

      expect(engine.newGameCalls, equals(1));
      _assertExpectedReviewAndAggregates(filename, json, review, engine);

      // Threefold draw sets W_after = 50.0, endgame material drops <= 13, 0 errors.
      expect(review.plies.last.winAfter, equals(50.0));
      expect(review.plies.last.phase, equals(GamePhase.endgame));
      expect(review.plies.where((p) => p.label.isError), isEmpty);
    });

    test('Fixture 3: Tactical French Greek Gift (36 plies, verified Brilliant, Great, and missedPunishment)', () async {
      const filename = 'tactical_brilliant_great_miss.json';
      final json = _loadFixture(filename);
      final config = json['config'] as Map<String, dynamic>;
      final engine = FixtureEngineService.fromFixtureJson(json);
      final budget = EngineBudget(
        nodes: config['nodes'] as int,
        threads: config['threads'] as int,
        hashMb: config['hashMb'] as int,
      );
      final movesUci = (json['movesUci'] as List<dynamic>).cast<String>();
      final initialFen = json['initialFen'] as String;

      final sharedCache = <String, EngineAnalysisResult>{};
      final reviewer = GameReviewer(
        engine: engine,
        openingBook: openingBook,
        externalEvalCache: sharedCache,
      );

      final review1 = await reviewer.reviewGame(
        initialFen: initialFen,
        movesUci: movesUci,
        budget: budget,
      );

      expect(engine.newGameCalls, equals(1));
      _assertExpectedReviewAndAggregates(filename, json, review1, engine);

      // Verify genuine Brilliant (11. Bxh7+!), Great (12. Ng5+!), and Miss (15... Nc4?! & 16. Nxe6+):
      final brilliantPly = review1.plies[20]; // Ply 21
      expect(brilliantPly.playedMoveUci, equals('d3h7'));
      expect(brilliantPly.label, equals(ClassificationLabel.brilliant));
      expect(brilliantPly.isSacrifice, isTrue);
      expect(brilliantPly.seeScore, lessThanOrEqualTo(-2));
      expect(brilliantPly.usedMultiPv2, isTrue);

      final greatPly = review1.plies[22]; // Ply 23
      expect(greatPly.playedMoveUci, equals('f3g5'));
      expect(greatPly.label, equals(ClassificationLabel.great));
      expect(greatPly.isSacrifice, isFalse);
      expect(greatPly.secondBestDeltaW, greaterThanOrEqualTo(15.0));

      final missPly = review1.plies[29]; // Ply 30
      expect(missPly.playedMoveUci, equals('e5c4'));
      expect(missPly.label, equals(ClassificationLabel.mistake));
      expect(missPly.missedPunishment, isTrue);

      // Replaying using externalEvalCache produces identical results with 0 extra engine calls.
      final callsBeforeSecondRun = engine.recordedCalls.length;
      final review2 = await reviewer.reviewGame(
        initialFen: initialFen,
        movesUci: movesUci,
        budget: budget,
      );
      expect(engine.recordedCalls.length, equals(callsBeforeSecondRun));

      for (var i = 0; i < review1.plies.length; i++) {
        expect(review2.plies[i].label, equals(review1.plies[i].label));
        expect(review2.plies[i].cpLoss, equals(review1.plies[i].cpLoss));
        expect(review2.plies[i].phase, equals(review1.plies[i].phase));
        expect(review2.plies[i].missedPunishment, equals(review1.plies[i].missedPunishment));
      }
      final agg1 = Aggregates.compute(review1);
      final agg2 = Aggregates.compute(review2);
      expect(agg2.white.compositeAccuracy, equals(agg1.white.compositeAccuracy));
      expect(agg2.black.compositeAccuracy, equals(agg1.black.compositeAccuracy));
      expect(agg2.white.acpl, equals(agg1.white.acpl));
      expect(agg2.black.acpl, equals(agg1.black.acpl));
    });
  });
}
