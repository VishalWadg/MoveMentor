import 'dart:convert';
import 'dart:io';
import 'package:chess/chess.dart' as ch;
import 'package:test/test.dart';
import 'package:chess_review_core/chess_review_core.dart';

/// Mock engine for testing call skipping rules.
class MockEngineService implements EngineServicePort {
  final List<String> analyzedFens = [];

  @override
  String get engineVersion => 'MockEngine 1.0';

  @override
  Future<bool> checkHealth() async => true;

  @override
  Future<void> newGame() async {}

  @override
  Future<EngineAnalysisResult> analyse(
    String fen, {
    int multiPv = 1,
    required EngineBudget budget,
  }) async {
    analyzedFens.add(fen);
    return EngineAnalysisResult(
      fen: fen,
      engineVersion: engineVersion,
      budget: budget,
      lines: [
        const EnginePvLine(
          multiPvRank: 1,
          cp: 50,
          winPercent: 55.0,
          moveUci: 'e2e4',
          pv: ['e2e4'],
        ),
      ],
      nodes: budget.nodes,
    );
  }

  @override
  Future<void> dispose() async {}
}

File _resolveFixture() {
  final candidate1 = File('test/fixtures/italian_game_500k.json');
  if (candidate1.existsSync()) return candidate1;
  final candidate2 = File('packages/chess_review_core/test/fixtures/italian_game_500k.json');
  if (candidate2.existsSync()) return candidate2;
  throw StateError('Fixture file italian_game_500k.json not found');
}

void main() {
  const classifier = Classifier();

  group('Test 4: Hung queen gives deltaW > 30 for BOTH colours', () {
    test('White hangs queen: deltaW > 30 and classified as Blunder', () {
      // White was equal (cp 0), plays a move that hangs Queen.
      // Opponent (Black) now has +900 cp advantage.
      final result = classifier.classifyMove(
        playedMoveUci: 'd1h5',
        moverScoreBefore: const PositionScore(cp: 0, bestMoveUci: 'd2d4', pv: ['d2d4']),
        opponentScoreAfter: const PositionScore(cp: 900, bestMoveUci: 'g8f6', pv: ['g8f6']),
        legalMovesCount: 20,
      );

      expect(result.winBefore, closeTo(50.0, 0.1));
      expect(result.winAfter, lessThan(10.0));
      expect(result.deltaW, greaterThan(30.0));
      expect(result.label, equals(ClassificationLabel.blunder));
    });

    test('Black hangs queen: deltaW > 30 and classified as Blunder', () {
      // Black was equal (cp 0 from Black's perspective), plays a move hanging Queen.
      // Opponent (White) now has +900 cp advantage from White's perspective.
      final result = classifier.classifyMove(
        playedMoveUci: 'd8h4',
        moverScoreBefore: const PositionScore(cp: 0, bestMoveUci: 'd7d5', pv: ['d7d5']),
        opponentScoreAfter: const PositionScore(cp: 900, bestMoveUci: 'g1f3', pv: ['g1f3']),
        legalMovesCount: 20,
      );

      expect(result.winBefore, closeTo(50.0, 0.1));
      expect(result.winAfter, lessThan(10.0));
      expect(result.deltaW, greaterThan(30.0));
      expect(result.label, equals(ClassificationLabel.blunder));
    });
  });

  group('Test 5: Mirror property: colour-flipped positions give identical deltas and labels', () {
    test('Identical advantage and drop give identical deltas and labels', () {
      // White mover: cp 150 before, opponent -100 after (mover lost advantage)
      final whiteResult = classifier.classifyMove(
        playedMoveUci: 'a2a3',
        moverScoreBefore: const PositionScore(cp: 150, bestMoveUci: 'd2d4', pv: ['d2d4']),
        opponentScoreAfter: const PositionScore(cp: -100, bestMoveUci: 'e7e5', pv: ['e7e5']),
        legalMovesCount: 20,
      );

      // Black mover: identical cp 150 from Black's view, opponent -100 from White's view
      final blackResult = classifier.classifyMove(
        playedMoveUci: 'a7a6',
        moverScoreBefore: const PositionScore(cp: 150, bestMoveUci: 'd7d5', pv: ['d7d5']),
        opponentScoreAfter: const PositionScore(cp: -100, bestMoveUci: 'e2e4', pv: ['e2e4']),
        legalMovesCount: 20,
      );

      expect(whiteResult.winBefore, closeTo(blackResult.winBefore, 1e-9));
      expect(whiteResult.winAfter, closeTo(blackResult.winAfter, 1e-9));
      expect(whiteResult.deltaW, closeTo(blackResult.deltaW, 1e-9));
      expect(whiteResult.label, equals(blackResult.label));
      expect(whiteResult.accuracy, closeTo(blackResult.accuracy, 1e-9));
    });
  });

  group('Test 6: Label table under Lichess-style preset', () {
    test('top move 0.5 -> Best', () {
      final res = classifier.classifyRaw(
        winBefore: 52.0,
        winAfter: 51.5,
        deltaW: 0.5,
        isEngineTopMove: true,
      );
      expect(res, equals(ClassificationLabel.best));
    });

    test('non-top move 0.5 -> Excellent', () {
      final res = classifier.classifyRaw(
        winBefore: 52.0,
        winAfter: 51.5,
        deltaW: 0.5,
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.excellent));
    });

    test('empty PV / unknown top move 0.5 -> Excellent (never Best)', () {
      final res = classifier.classifyRaw(
        winBefore: 52.0,
        winAfter: 51.5,
        deltaW: 0.5,
        hasEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.excellent));
    });

    test('1.5 -> Excellent', () {
      final res = classifier.classifyRaw(
        winBefore: 52.0,
        winAfter: 50.5,
        deltaW: 1.5,
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.excellent));
    });

    test('5.0 -> Good', () {
      final res = classifier.classifyRaw(
        winBefore: 55.0,
        winAfter: 50.0,
        deltaW: 5.0,
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.good));
    });

    test('12.0 -> Inaccuracy', () {
      final res = classifier.classifyRaw(
        winBefore: 55.0,
        winAfter: 43.0,
        deltaW: 12.0,
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.inaccuracy));
    });

    test('25.0 -> Mistake (when no 60->40 swing)', () {
      final res = classifier.classifyRaw(
        winBefore: 70.0,
        winAfter: 45.0,
        deltaW: 25.0,
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.mistake));
    });

    test('35.0 -> Blunder', () {
      final res = classifier.classifyRaw(
        winBefore: 70.0,
        winAfter: 35.0,
        deltaW: 35.0,
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.blunder));
    });

    test('65.0 -> 38.0 (deltaW 27) -> Blunder (swing rule beats Mistake band)', () {
      final res = classifier.classifyRaw(
        winBefore: 65.0,
        winAfter: 38.0,
        deltaW: 27.0,
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.blunder));
    });
  });

  group('Test 7: Blunder from winning position is Blunder, not Miss', () {
    test('80.0 -> 25.0 (deltaW 55) is Blunder, not Miss', () {
      final res = classifier.classifyRaw(
        winBefore: 80.0,
        winAfter: 25.0,
        deltaW: 55.0,
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.blunder));
      // ClassificationLabel does not even have 'miss'
      expect(ClassificationLabel.values.map((e) => e.name), isNot(contains('miss')));
    });
  });

  group('Test 9: Terminal positions make no engine call', () {
    test('checkmate position after move skips engine call for fenAfter', () async {
      final mockEngine = MockEngineService();
      final reviewer = PositionReviewer(engine: mockEngine, classifier: classifier);

      final result = await reviewer.reviewMove(
        fenBefore: 'r2qk2r/ppp1n2p/4BQ2/3p4/8/8/P4PPP/5RK1 w - - 1 20',
        fenAfter: 'r2qk2r/ppp1nQ1p/4B3/3p4/8/8/P4PPP/5RK1 b - - 2 20',
        playedMoveUci: 'f6f7',
        legalMovesCount: 30,
        isCheckmateAfter: true,
        budget: const EngineBudget(nodes: 50000),
      );

      expect(mockEngine.analyzedFens.length, equals(1));
      expect(mockEngine.analyzedFens.first, equals('r2qk2r/ppp1n2p/4BQ2/3p4/8/8/P4PPP/5RK1 w - - 1 20'));
      expect(result.winAfter, equals(100.0));
      expect(result.label, equals(ClassificationLabel.best));
    });

    test('stalemate/draw position after move skips engine call for fenAfter', () async {
      final mockEngine = MockEngineService();
      final reviewer = PositionReviewer(engine: mockEngine, classifier: classifier);

      final result = await reviewer.reviewMove(
        fenBefore: '7k/5Q2/6K1/8/8/8/8/8 w - - 0 1',
        fenAfter: '7k/8/6K1/8/8/8/8/8 b - - 1 1',
        playedMoveUci: 'f7f8',
        legalMovesCount: 5,
        isDrawAfter: true,
        budget: const EngineBudget(nodes: 50000),
      );

      expect(mockEngine.analyzedFens.length, equals(1));
      expect(result.winAfter, equals(50.0));
    });

    test('forced move (legalMovesCount == 1) skips engine entirely (0 calls)', () async {
      final mockEngine = MockEngineService();
      final reviewer = PositionReviewer(engine: mockEngine, classifier: classifier);

      final result = await reviewer.reviewMove(
        fenBefore: 'r2q1k1r/ppp1n2p/4BQ2/3p4/8/8/P4PPP/5RK1 b - - 0 19',
        fenAfter: 'r2qk2r/ppp1n2p/4BQ2/3p4/8/8/P4PPP/5RK1 w - - 1 20',
        playedMoveUci: 'f8e8',
        legalMovesCount: 1, // only legal move
        budget: const EngineBudget(nodes: 50000),
      );

      expect(mockEngine.analyzedFens.isEmpty, isTrue);
      expect(result.isForced, isTrue);
      expect(result.label, equals(ClassificationLabel.best));
    });
  });

  group('Item 4: Consecutive plies zero-sum identity: W_after(t) + W_before(t+1) = 100', () {
    test('Every consecutive pair of plies sums to 100 in the fixture', () {
      final file = _resolveFixture();
      expect(file.existsSync(), isTrue);

      final decoded = jsonDecode(file.readAsStringSync());
      final plies = decoded is List ? decoded : (decoded as Map)['plies'] as List;

      expect(plies.length, equals(39));

      for (var t = 0; t < plies.length - 1; t++) {
        final current = plies[t] as Map<String, dynamic>;
        final next = plies[t + 1] as Map<String, dynamic>;

        final plyCurrent = current['ply'] as int;
        final plyNext = next['ply'] as int;

        final wAfterT = (current['wAfter'] as num).toDouble();
        final wBeforeNext = (next['wBefore'] as num).toDouble();

        final sum = wAfterT + wBeforeNext;
        expect(
          sum,
          closeTo(100.0, 1e-4),
          reason: 'Failed zero-sum identity between ply $plyCurrent and ply $plyNext: $wAfterT + $wBeforeNext = $sum',
        );
      }
    });
  });

  group('Item 1: Fixture move replay and metadata validation', () {
    test('Replay every UCI move through chess library; fail on any illegal move', () {
      final file = _resolveFixture();
      final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

      // Check engine metadata
      final engine = decoded['engine'] as Map<String, dynamic>;
      expect(engine['idName'], isNotEmpty);
      expect(engine['build'], isNotEmpty);
      expect(engine['net'], isNotEmpty);
      expect(engine['idName'], equals('Stockfish 19 WASM Multithreaded'));
      expect(engine['net'], equals('nn-1a298aa575a0.nnue'));

      final plies = decoded['plies'] as List<dynamic>;
      expect(plies.length, equals(39));

      final game = ch.Chess();
      for (var i = 0; i < plies.length; i++) {
        final p = plies[i] as Map<String, dynamic>;
        final plyNum = p['ply'] as int;
        final uci = p['uci'] as String;
        final san = p['san'] as String;

        // Verify ply 6
        if (plyNum == 6) {
          expect(uci, equals('f8c5'), reason: 'Ply 6 UCI must be f8c5 (not c8c5)');
          expect(san, equals('Bc5'));
        }

        final from = uci.substring(0, 2);
        final to = uci.substring(2, 4);
        final promotion = uci.length > 4 ? uci.substring(4, 5) : null;

        final moveResult = game.move({
          'from': from,
          'to': to,
          'promotion': promotion,
        });

        expect(
          moveResult,
          isNot(equals(false)),
          reason: 'Ply $plyNum: Illegal move $uci ($san) at position ${game.fen}',
        );
      }

      expect(game.in_checkmate, isTrue, reason: 'Game must end in checkmate at ply 39');
    });
  });

  group('Item 3: Forced move derived ONLY from legal-move count == 1 & ply 22 check', () {
    test('Check ply 22: Ke7 is legal, legal move count == 2, so forced is false', () {
      // Position before ply 22: White just played 11. Bxf7+
      const fenBeforePly22 = 'r1bqk2r/pppp1Bpp/2n5/8/3P4/1Q3N2/P4PPP/b1B2RK1 b kq - 0 11';
      final game = ch.Chess.fromFEN(fenBeforePly22);

      final legalMoves = game.moves({'verbose': true});
      final uciMoves = legalMoves.map((m) => '${(m as Map)['from']}${m['to']}').toList();

      expect(uciMoves, contains('e8f8')); // Kf8
      expect(uciMoves, contains('e8e7')); // Ke7
      expect(legalMoves.length, equals(2));

      // Because legal move count is 2 (not 1), ply 22 is NOT forced
      final isForced = legalMoves.length == 1;
      expect(isForced, isFalse);
    });
  });

  group('Saturation guard behavior (Plies 30 & 34 resolution)', () {
    test('wBefore <= 5 and cpLoss >= 300 forces at least Mistake', () {
      final res = classifier.classifyRaw(
        winBefore: 3.5,
        winAfter: 3.0,
        deltaW: 0.5, // deltaW < 1 would normally be Excellent
        moverCpBefore: -700,
        moverCpAfter: -1000, // cp loss = 300
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.mistake));
    });

    test('wBefore <= 5 and cpLoss >= 600 forces Blunder', () {
      final res = classifier.classifyRaw(
        winBefore: 3.5,
        winAfter: 3.0,
        deltaW: 0.5,
        moverCpBefore: -400,
        moverCpAfter: -1000, // cp loss = 600
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.blunder));
    });

    test('wBefore <= 5 and cpLoss < 300 with deltaW < 1 is Excellent (not Good!)', () {
      // Replicates plies 30 and 34: cp loss is minimal (~28 cp), deltaW < 1
      final res = classifier.classifyRaw(
        winBefore: 3.82,
        winAfter: 3.46,
        deltaW: 0.36,
        moverCpBefore: -876,
        moverCpAfter: -904, // cp loss = 28 cp
        isEngineTopMove: false,
      );
      expect(res, equals(ClassificationLabel.excellent));
    });
  });

  group('Forced mate defense vs newly appeared forced mate blunder tests', () {
    test('Mover facing forced mate (-3) plays top move to delay mate (-2): classified as Best, NOT Blunder', () {
      final res = classifier.classifyMove(
        playedMoveUci: 'f8e8',
        moverScoreBefore: const PositionScore(mate: -3, bestMoveUci: 'f8e8'),
        opponentScoreAfter: const PositionScore(mate: 2, bestMoveUci: 'f6f7'),
        legalMovesCount: 2,
      );
      // Mover was already facing forced mate (-3); opponent mate (+2) was ALREADY there.
      // Therefore, this move did NOT cause a forced mate to appear that wasn't there before.
      expect(res.deltaW, equals(0.0));
      expect(res.label, equals(ClassificationLabel.best));
    });

    test('Mover had mate in hand (+2) but blunders into opponent mate (+1): classified as Blunder', () {
      final res = classifier.classifyMove(
        playedMoveUci: 'h2h3',
        moverScoreBefore: const PositionScore(mate: 2, bestMoveUci: 'd1d8'),
        opponentScoreAfter: const PositionScore(mate: 1, bestMoveUci: 'a1h1'),
        legalMovesCount: 15,
      );
      expect(res.label, equals(ClassificationLabel.blunder));
    });

    test('Opponent forced mate appears from equal position (null -> +1): classified as Blunder', () {
      final res = classifier.classifyMove(
        playedMoveUci: 'f2f3',
        moverScoreBefore: const PositionScore(cp: 0, bestMoveUci: 'd2d4'),
        opponentScoreAfter: const PositionScore(mate: 1, bestMoveUci: 'd8h4'),
        legalMovesCount: 20,
      );
      expect(res.label, equals(ClassificationLabel.blunder));
    });
  });

  group('Top move identification and empty PV behavior', () {
    test('PositionScore with bestMoveUci and empty pv correctly identifies top move -> Best', () {
      final res = classifier.classifyMove(
        playedMoveUci: 'e2e4',
        moverScoreBefore: const PositionScore(cp: 30, bestMoveUci: 'e2e4', pv: []),
        opponentScoreAfter: const PositionScore(cp: -25, bestMoveUci: 'c7c5'),
      );
      expect(res.isEngineTopMove, isTrue);
      expect(res.label, equals(ClassificationLabel.best));
    });

    test('PositionScore with pv and null bestMoveUci derives top move from pv.first -> Best', () {
      final res = classifier.classifyMove(
        playedMoveUci: 'e2e4',
        moverScoreBefore: const PositionScore(cp: 30, pv: ['e2e4', 'e7e5']),
        opponentScoreAfter: const PositionScore(cp: -25, bestMoveUci: 'c7c5'),
      );
      expect(res.isEngineTopMove, isTrue);
      expect(res.label, equals(ClassificationLabel.best));
    });

    test('Empty PV and null bestMoveUci enforces bands only (never Best, Great, or Brilliant)', () {
      final res = classifier.classifyMove(
        playedMoveUci: 'e2e4',
        moverScoreBefore: const PositionScore(cp: 30, pv: []),
        opponentScoreAfter: const PositionScore(cp: -30, bestMoveUci: 'c7c5'),
      );
      expect(res.isEngineTopMove, isFalse);
      expect(res.deltaW, closeTo(0.0, 0.1));
      // deltaW < 1.0 without top move falls to Excellent
      expect(res.label, equals(ClassificationLabel.excellent));
    });
  });

  group('PositionReviewer: forced move score preservation & one-eval-per-position', () {
    test('PositionReviewer preserves moverScoreBefore for forced moves without resetting to 50.0', () async {
      final mockEngine = MockEngineService();
      final reviewer = PositionReviewer(engine: mockEngine, classifier: classifier);

      final result = await reviewer.reviewMove(
        fenBefore: 'r2q1k1r/ppp1n2p/4BQ2/3p4/8/8/P4PPP/5RK1 b - - 0 19',
        fenAfter: 'r2qk2r/ppp1n2p/4BQ2/3p4/8/8/P4PPP/5RK1 w - - 1 20',
        playedMoveUci: 'f8e8',
        legalMovesCount: 1, // forced move
        moverScoreBefore: const PositionScore(mate: -1), // Losing: 0% win probability
        budget: const EngineBudget(nodes: 50000),
      );

      // Skips engine call
      expect(mockEngine.analyzedFens.isEmpty, isTrue);
      expect(result.isForced, isTrue);
      expect(result.label, equals(ClassificationLabel.best));
      expect(result.winBefore, equals(0.0));
      expect(result.winAfter, equals(0.0));
      expect(result.deltaW, equals(0.0));
    });

    test('PositionReviewer reuses moverScoreBefore and avoids calling engine for fenBefore', () async {
      final mockEngine = MockEngineService();
      final reviewer = PositionReviewer(engine: mockEngine, classifier: classifier);

      await reviewer.reviewMove(
        fenBefore: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        fenAfter: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
        playedMoveUci: 'e7e5',
        legalMovesCount: 20,
        moverScoreBefore: const PositionScore(cp: -22, bestMoveUci: 'c7c5'),
        budget: const EngineBudget(nodes: 50000),
      );

      // Only fenAfter should be analyzed because moverScoreBefore was provided!
      expect(mockEngine.analyzedFens.length, equals(1));
      expect(mockEngine.analyzedFens.first, equals('rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2'));
    });
  });

  group('Dynamic zero-sum identity via Classifier.classifyMove on fixture', () {
    test('Reclassifying entire fixture through Classifier yields W_after(t) + W_before(t+1) == 100 for all plies', () {
      final file = _resolveFixture();
      final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final plies = decoded['plies'] as List<dynamic>;

      final results = <MoveClassificationResult>[];
      for (var i = 0; i < plies.length; i++) {
        final p = plies[i] as Map<String, dynamic>;
        final evalBefore = p['evalBefore'] as Map<String, dynamic>;
        final evalAfter = p['evalAfter'] as Map<String, dynamic>;
        final uci = p['uci'] as String;
        final isCheckmate = (i == plies.length - 1);

        final scoreBefore = PositionScore(
          cp: evalBefore['cp'] as int?,
          mate: evalBefore['mate'] as int?,
          bestMoveUci: evalBefore['bestMove'] as String?,
          pv: (evalBefore['pv'] as List<dynamic>?)?.cast<String>() ?? const [],
        );

        final scoreAfter = PositionScore(
          cp: evalAfter['cp'] as int?,
          mate: evalAfter['mate'] as int?,
          bestMoveUci: evalAfter['bestMove'] as String?,
          pv: (evalAfter['pv'] as List<dynamic>?)?.cast<String>() ?? const [],
        );

        final res = classifier.classifyMove(
          playedMoveUci: uci,
          moverScoreBefore: scoreBefore,
          opponentScoreAfter: scoreAfter,
          isCheckmateAfter: isCheckmate,
          legalMovesCount: (p['ply'] == 38) ? 1 : 20,
        );
        results.add(res);
      }

      for (var t = 0; t < results.length - 1; t++) {
        final sum = results[t].winAfter + results[t + 1].winBefore;
        expect(
          sum,
          closeTo(100.0, 1e-4),
          reason: 'Dynamic classifier zero-sum failed between ply ${t + 1} and ${t + 2}: ${results[t].winAfter} + ${results[t + 1].winBefore} = $sum',
        );
      }
    });
  });
}
