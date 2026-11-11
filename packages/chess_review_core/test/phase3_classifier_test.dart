import 'package:test/test.dart';
import 'package:chess_review_core/chess_review_core.dart';

class RecordingEngineService implements EngineServicePort {
  final Map<String, List<EnginePvLine>> responses;
  final List<({String fen, int multiPv})> recordedCalls = [];
  int newGameCalls = 0;

  RecordingEngineService(this.responses);

  @override
  String get engineVersion => 'MockDeterministicSF 1.0';

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
    recordedCalls.add((fen: fen, multiPv: multiPv));
    final allLines = responses[fen] ?? const [];
    final selected = allLines.take(multiPv).toList();
    return EngineAnalysisResult(
      fen: fen,
      engineVersion: engineVersion,
      budget: budget,
      lines: selected,
      nodes: budget.nodes,
    );
  }

  @override
  Future<void> dispose() async {}
}

class InMemoryOpeningBook extends OpeningBookPort {
  final Map<String, OpeningEntry> entriesByEpd;

  InMemoryOpeningBook(this.entriesByEpd);

  @override
  OpeningEntry? lookupByEpd(String epd) => entriesByEpd[epd];
}

void main() {
  const classifier = Classifier();
  const budget = EngineBudget(nodes: 10000, threads: 1, hashMb: 16);

  group('Test 8: Forced move, recapture, and W_before > 90 NEVER produce Great/Brilliant', () {
    test('forced move never produces Great or Brilliant even with sacrifice/gap', () {
      final resBrilliantAttempt = classifier.classifyRaw(
        winBefore: 50.0,
        winAfter: 50.0,
        deltaW: 0.0,
        isForced: true,
        isEngineTopMove: true,
        isSacrifice: true,
        hasNonSacAlternativeWithin1Point: false,
        secondBestDeltaW: 25.0,
      );
      expect(resBrilliantAttempt, equals(ClassificationLabel.best));
      expect(resBrilliantAttempt, isNot(equals(ClassificationLabel.brilliant)));
      expect(resBrilliantAttempt, isNot(equals(ClassificationLabel.great)));
    });

    test('recapture never produces Great or Brilliant', () {
      final resSacRecapture = classifier.classifyRaw(
        winBefore: 55.0,
        winAfter: 55.0,
        deltaW: 0.0,
        isRecapture: true,
        isEngineTopMove: true,
        isSacrifice: true,
        hasNonSacAlternativeWithin1Point: false,
      );
      expect(resSacRecapture, equals(ClassificationLabel.best));

      final resOnlyRecapture = classifier.classifyRaw(
        winBefore: 55.0,
        winAfter: 55.0,
        deltaW: 0.0,
        isRecapture: true,
        isEngineTopMove: true,
        isSacrifice: false,
        secondBestDeltaW: 25.0,
      );
      expect(resOnlyRecapture, equals(ClassificationLabel.best));
    });

    test('W_before > 90 never produces Great or Brilliant', () {
      final resWinningSac = classifier.classifyRaw(
        winBefore: 90.1,
        winAfter: 90.0,
        deltaW: 0.1,
        isEngineTopMove: true,
        isSacrifice: true,
        hasNonSacAlternativeWithin1Point: false,
      );
      expect(resWinningSac, equals(ClassificationLabel.best));

      final resWinningOnlyMove = classifier.classifyRaw(
        winBefore: 92.0,
        winAfter: 92.0,
        deltaW: 0.0,
        isEngineTopMove: true,
        isSacrifice: false,
        secondBestDeltaW: 30.0,
      );
      expect(resWinningOnlyMove, equals(ClassificationLabel.best));
    });
  });

  group('Brilliant classification rules (MultiPV 2, SEE <= -2 sustained, [35,90])', () {
    test('sustained sacrifice without non-sac alternative within 1 point -> Brilliant', () {
      final res = classifier.classifyRaw(
        winBefore: 67.6,
        winAfter: 67.6,
        deltaW: 0.0,
        isEngineTopMove: true,
        isSacrifice: true,
        hasNonSacAlternativeWithin1Point: false,
      );
      expect(res, equals(ClassificationLabel.brilliant));
    });

    test('equally good non-sacrificial alternative within 1 point blocks Brilliant -> Best', () {
      final res = classifier.classifyRaw(
        winBefore: 67.6,
        winAfter: 67.6,
        deltaW: 0.0,
        isEngineTopMove: true,
        isSacrifice: true,
        hasNonSacAlternativeWithin1Point: true,
      );
      expect(res, equals(ClassificationLabel.best));
    });

    test('missing MultiPV 2 confirmation (null) blocks Brilliant', () {
      final res = classifier.classifyRaw(
        winBefore: 67.6,
        winAfter: 67.6,
        deltaW: 0.0,
        isEngineTopMove: true,
        isSacrifice: true,
        hasNonSacAlternativeWithin1Point: null,
      );
      expect(res, equals(ClassificationLabel.best));
    });

    test('W_after < 35 or W_after > 90 blocks Brilliant', () {
      final lowAfter = classifier.classifyRaw(
        winBefore: 34.0,
        winAfter: 34.0,
        deltaW: 0.0,
        isEngineTopMove: true,
        isSacrifice: true,
        hasNonSacAlternativeWithin1Point: false,
      );
      expect(lowAfter, equals(ClassificationLabel.best));

      final highAfter = classifier.classifyRaw(
        winBefore: 89.0,
        winAfter: 91.0,
        deltaW: 0.0,
        isEngineTopMove: true,
        isSacrifice: true,
        hasNonSacAlternativeWithin1Point: false,
      );
      expect(highAfter, equals(ClassificationLabel.best));
    });

    test('non-top move within 1 point with sustained sac and no non-sac alternative -> Brilliant', () {
      final res = classifier.classifyRaw(
        winBefore: 68.0,
        winAfter: 67.4,
        deltaW: 0.6,
        isEngineTopMove: false,
        isSacrifice: true,
        hasNonSacAlternativeWithin1Point: false,
      );
      expect(res, equals(ClassificationLabel.brilliant));
    });
  });

  group('Great classification rules & turnsTheGameVariant', () {
    test('top move, not sac, secondBestDeltaW >= 15 -> Great', () {
      final res = classifier.classifyRaw(
        winBefore: 60.0,
        winAfter: 60.0,
        deltaW: 0.0,
        isEngineTopMove: true,
        isSacrifice: false,
        secondBestDeltaW: 15.0,
      );
      expect(res, equals(ClassificationLabel.great));
    });

    test('secondBestDeltaW < 15 with turnsTheGameVariant OFF (default) -> Best', () {
      final res = classifier.classifyRaw(
        winBefore: 42.0,
        winAfter: 55.0,
        deltaW: 0.0,
        isEngineTopMove: true,
        isSacrifice: false,
        secondBestDeltaW: 8.0,
        myWinBeforeOpponent: 35.0,
      );
      expect(res, equals(ClassificationLabel.best));
    });

    test('turnsTheGameVariant ON allows Great when turning game from behind', () {
      const customClassifier = Classifier(
        config: ClassificationConfig(turnsTheGameVariant: true),
      );
      final res = customClassifier.classifyRaw(
        winBefore: 60.0,
        winAfter: 60.0,
        deltaW: 0.0,
        isEngineTopMove: true,
        isSacrifice: false,
        secondBestDeltaW: 8.0,
        myWinBeforeOpponent: 35.0,
      );
      expect(res, equals(ClassificationLabel.great));
    });

    test('non-top move cannot be Great even with deltaW < 1 and secondBestDeltaW >= 15', () {
      final res = classifier.classifyRaw(
        winBefore: 60.0,
        winAfter: 59.5,
        deltaW: 0.5,
        isEngineTopMove: false,
        isSacrifice: false,
        secondBestDeltaW: 20.0,
      );
      expect(res, equals(ClassificationLabel.excellent));
    });
  });

  group('Miss (missedPunishment flag)', () {
    test('true when opponent drop >= 20 and my gain < 0.7 * D, never replaces Mistake/Blunder', () {
      // Opponent dropped D=30 (60 -> 30). My win before opp move was 40.
      // 0.7 * 30 = 21 -> must end >= 61 to punish.
      // Case 1: I blunder back (70 -> 40, deltaW = 30 -> gain = 0 < 21)
      final missedBlunder = classifier.classifyMove(
        playedMoveUci: 'd2d3',
        moverScoreBefore: const PositionScore(cp: 230, bestMoveUci: 'e4d5'), // ~70.0%
        opponentScoreAfter: const PositionScore(cp: 120, bestMoveUci: 'e7e5'), // opp ~60.9%, my ~39.1% (deltaW > 30)
        previousOpponentDrop: 30.0,
        myWinBeforeOpponent: 40.0,
      );
      expect(missedBlunder.label, equals(ClassificationLabel.blunder));
      expect(missedBlunder.missedPunishment, isTrue);

      // Case 2: I play Good move retaining >= 0.7*D (70 -> 65 -> gain = 25 >= 21)
      final punished = classifier.classifyMove(
        playedMoveUci: 'e4d5',
        moverScoreBefore: const PositionScore(cp: 230, bestMoveUci: 'e4d5'), // ~70.0%
        opponentScoreAfter: const PositionScore(cp: -170, bestMoveUci: 'c6e7'), // opp ~34.7%, my ~65.3%
        previousOpponentDrop: 30.0,
        myWinBeforeOpponent: 40.0,
      );
      expect(punished.label, equals(ClassificationLabel.good));
      expect(punished.missedPunishment, isFalse);

      // Case 3: Opponent drop was only 19.0 < 20.0 -> missedPunishment MUST be false
      final smallOppDrop = classifier.classifyMove(
        playedMoveUci: 'a2a3',
        moverScoreBefore: const PositionScore(cp: 200, bestMoveUci: 'e4d5'),
        opponentScoreAfter: const PositionScore(cp: 0, bestMoveUci: 'e7e5'),
        previousOpponentDrop: 19.0,
        myWinBeforeOpponent: 45.0,
      );
      expect(smallOppDrop.missedPunishment, isFalse);
    });
  });

  group('Book EPD matching & GameReviewer integration (MultiPV 2, Brilliant, Test 10 Determinism)', () {
    test('Book uses EPD position matching (transposition via different move order)', () async {
      // 1.e4 e6 2.d4 d5 and 1.d4 e6 2.e4 d5 reach identical EPD
      const targetEpd = 'rnbqkbnr/ppp2ppp/4p3/3p4/3PP3/8/PPP2PPP/RNBQKBNR w KQkq d6';
      final book = InMemoryOpeningBook({
        targetEpd: const OpeningEntry(
          eco: 'C00',
          name: 'French Defense',
          epd: targetEpd,
        ),
      });

      final engine = RecordingEngineService({});
      final reviewer = GameReviewer(
        engine: engine,
        openingBook: book,
        classifier: classifier,
      );

      final resultOrderA = await reviewer.reviewGame(
        movesUci: ['e2e4', 'e7e6', 'd2d4', 'd7d5'],
        budget: budget,
      );
      final resultOrderB = await reviewer.reviewGame(
        movesUci: ['d2d4', 'e7e6', 'e2e4', 'd7d5'],
        budget: budget,
      );

      expect(resultOrderA.plies.last.isBook, isTrue);
      expect(resultOrderA.plies.last.label, equals(ClassificationLabel.book));
      expect(resultOrderB.plies.last.isBook, isTrue);
      expect(resultOrderB.plies.last.label, equals(ClassificationLabel.book));
    });

    test('GameReviewer triggers MultiPV 2 only on candidates, detects Brilliant Rxc6, and blocks recapture', () async {
      // Start from custom middlegame FEN where White plays Rxc6! (sustained sacrifice)
      // Black also had a capture before or doesn't: test Rxc6 as Brilliant!
      const fen0 = '4k3/1p3ppp/2n5/8/8/8/5PPP/2R3K1 w - - 0 1';
      const fen1 = '4k3/1p3ppp/2R5/8/8/8/5PPP/6K1 b - - 0 1'; // After c1c6 (Rxc6)
      const fen2 = '4k3/1p3pp1/2R4p/8/8/8/5PPP/6K1 w - - 0 2'; // After h7h6

      final wC6 = WinPercent.fromCp(200); // ~67.6%
      final wAlt = WinPercent.fromCp(50); // ~54.6% (non-sac alternative > 1 point worse)
      final wBlack = WinPercent.fromCp(-200); // Black's view ~32.4% -> White 67.6%

      final engine = RecordingEngineService({
        fen0: [
          EnginePvLine(
            multiPvRank: 1,
            cp: 200,
            winPercent: wC6,
            moveUci: 'c1c6',
            pv: const ['c1c6', 'b7c6', 'g1f1', 'e8d7', 'f1e2'],
          ),
          EnginePvLine(
            multiPvRank: 2,
            cp: 50,
            winPercent: wAlt,
            moveUci: 'g1f1',
            pv: const ['g1f1', 'e8d7'],
          ),
        ],
        fen1: [
          EnginePvLine(
            multiPvRank: 1,
            cp: -200,
            winPercent: wBlack,
            moveUci: 'b7c6',
            pv: const ['b7c6', 'g1f1', 'e8d7', 'f1e2'],
          ),
        ],
        fen2: [
          EnginePvLine(
            multiPvRank: 1,
            cp: 150, // White +150 -> Black W_after = 36.4% vs W_before 32.4% (deltaW = 0)
            winPercent: WinPercent.fromCp(150),
            moveUci: 'g1f1',
            pv: const ['g1f1'],
          ),
        ],
      });

      final reviewer = GameReviewer(engine: engine, classifier: classifier);
      final review = await reviewer.reviewGame(
        initialFen: fen0,
        movesUci: ['c1c6', 'h7h6'],
        budget: budget,
      );

      final sacPly = review.plies[0];
      expect(sacPly.playedMoveUci, equals('c1c6'));
      expect(sacPly.isSacrifice, isTrue);
      expect(sacPly.usedMultiPv2, isTrue);
      expect(sacPly.label, equals(ClassificationLabel.brilliant));

      // Verify MultiPV 2 was called for candidate fen0, NOT called for non-top fen1 or fen2
      expect(
        engine.recordedCalls.any((c) => c.fen == fen0 && c.multiPv == 2),
        isTrue,
      );
      expect(
        engine.recordedCalls.any((c) => c.fen == fen1 && c.multiPv == 2),
        isFalse,
      );
      expect(
        engine.recordedCalls.any((c) => c.fen == fen2 && c.multiPv == 2),
        isFalse,
      );
    });

    test('GameReviewer derives isRecapture across plies and blocks Brilliant on recaptures', () async {
      // Position: Black Knight takes White Pawn on c6 (1... Nxc6), White recaptures 2. Rxc6 (recapture!)
      const fen0 = '4k3/1p3ppp/2P5/4n3/8/8/5PPP/2R3K1 b - - 0 1';
      const fen1 = '4k3/1p3ppp/2n5/8/8/8/5PPP/2R3K1 w - - 0 2'; // after e5c6 (Nxc6)
      const fen2 = '4k3/1p3ppp/2R5/8/8/8/5PPP/6K1 b - - 0 2'; // after c1c6 (Rxc6 recapture!)

      final engine = RecordingEngineService({
        fen0: [
          EnginePvLine(
            multiPvRank: 1,
            cp: -200,
            winPercent: WinPercent.fromCp(-200),
            moveUci: 'e5c6',
            pv: const ['e5c6'],
          ),
        ],
        fen1: [
          EnginePvLine(
            multiPvRank: 1,
            cp: 200,
            winPercent: WinPercent.fromCp(200),
            moveUci: 'c1c6',
            pv: const ['c1c6', 'b7c6', 'g1f1', 'e8d7'],
          ),
          EnginePvLine(
            multiPvRank: 2,
            cp: 0,
            winPercent: WinPercent.fromCp(0),
            moveUci: 'g1f1',
            pv: const ['g1f1'],
          ),
        ],
        fen2: [
          EnginePvLine(
            multiPvRank: 1,
            cp: -200,
            winPercent: WinPercent.fromCp(-200),
            moveUci: 'b7c6',
            pv: const ['b7c6', 'g1f1', 'e8d7'],
          ),
        ],
      });

      final reviewer = GameReviewer(engine: engine, classifier: classifier);
      final review = await reviewer.reviewGame(
        initialFen: fen0,
        movesUci: ['e5c6', 'c1c6'],
        budget: budget,
      );

      final recapturePly = review.plies[1];
      expect(recapturePly.isRecapture, isTrue);
      expect(recapturePly.label, equals(ClassificationLabel.best));
      expect(recapturePly.label, isNot(equals(ClassificationLabel.brilliant)));
      expect(recapturePly.label, isNot(equals(ClassificationLabel.great)));
    });

    test('MultiPV 2 is NOT called when top move W_before > 90 and deltaW < 10', () async {
      const fen0 = '4k3/8/8/8/8/8/5PPP/2R3K1 w - - 0 1';
      const fen1 = '4k3/8/8/8/8/8/5PPP/2R2K2 b - - 1 1';

      final w95 = WinPercent.fromCp(800); // > 90%
      final engine = RecordingEngineService({
        fen0: [
          EnginePvLine(
            multiPvRank: 1,
            cp: 800,
            winPercent: w95,
            moveUci: 'g1f1',
            pv: const ['g1f1'],
          ),
          EnginePvLine(
            multiPvRank: 2,
            cp: 200,
            winPercent: WinPercent.fromCp(200),
            moveUci: 'c1e1',
            pv: const ['c1e1'],
          ),
        ],
        fen1: [
          EnginePvLine(
            multiPvRank: 1,
            cp: -800,
            winPercent: 100.0 - w95,
            moveUci: 'e8d7',
            pv: const ['e8d7'],
          ),
        ],
      });

      final reviewer = GameReviewer(engine: engine, classifier: classifier);
      final review = await reviewer.reviewGame(
        initialFen: fen0,
        movesUci: ['g1f1'],
        budget: budget,
      );

      expect(review.plies.first.usedMultiPv2, isFalse);
      expect(review.plies.first.label, equals(ClassificationLabel.best));
      expect(
        engine.recordedCalls.any((c) => c.multiPv == 2),
        isFalse,
      );
    });

    test('Test 10: Determinism: same game twice produces identical output', () async {
      const fen0 = '4k3/1p3ppp/2n5/8/8/8/5PPP/2R3K1 w - - 0 1';
      const fen1 = '4k3/1p3ppp/2R5/8/8/8/5PPP/6K1 b - - 0 1';
      const fen2 = '4k3/1p3pp1/2R4p/8/8/8/5PPP/6K1 w - - 0 2';

      final responses = {
        fen0: [
          EnginePvLine(
            multiPvRank: 1,
            cp: 200,
            winPercent: WinPercent.fromCp(200),
            moveUci: 'c1c6',
            pv: const ['c1c6', 'b7c6', 'g1f1', 'e8d7'],
          ),
          EnginePvLine(
            multiPvRank: 2,
            cp: 50,
            winPercent: WinPercent.fromCp(50),
            moveUci: 'g1f1',
            pv: const ['g1f1', 'e8d7'],
          ),
        ],
        fen1: [
          EnginePvLine(
            multiPvRank: 1,
            cp: -200,
            winPercent: WinPercent.fromCp(-200),
            moveUci: 'b7c6',
            pv: const ['b7c6', 'g1f1', 'e8d7'],
          ),
          EnginePvLine(
            multiPvRank: 2,
            cp: 150,
            winPercent: WinPercent.fromCp(150),
            moveUci: 'h7h6',
            pv: const ['h7h6'],
          ),
        ],
        fen2: [
          EnginePvLine(
            multiPvRank: 1,
            cp: 700,
            winPercent: WinPercent.fromCp(700),
            moveUci: 'c6c8',
            pv: const ['c6c8'],
          ),
        ],
      };

      final engine1 = RecordingEngineService(responses);
      final engine2 = RecordingEngineService(responses);

      final review1 = await GameReviewer(engine: engine1, classifier: classifier).reviewGame(
        initialFen: fen0,
        movesUci: ['c1c6', 'h7h6'],
        budget: budget,
      );
      final review2 = await GameReviewer(engine: engine2, classifier: classifier).reviewGame(
        initialFen: fen0,
        movesUci: ['c1c6', 'h7h6'],
        budget: budget,
      );

      expect(review1.plies.length, equals(review2.plies.length));
      for (var i = 0; i < review1.plies.length; i++) {
        final a = review1.plies[i];
        final b = review2.plies[i];
        expect(a.label, equals(b.label));
        expect(a.winBefore, equals(b.winBefore));
        expect(a.winAfter, equals(b.winAfter));
        expect(a.deltaW, equals(b.deltaW));
        expect(a.accuracy, equals(b.accuracy));
        expect(a.isBook, equals(b.isBook));
        expect(a.isForced, equals(b.isForced));
        expect(a.isSacrifice, equals(b.isSacrifice));
        expect(a.isRecapture, equals(b.isRecapture));
        expect(a.missedPunishment, equals(b.missedPunishment));
        expect(a.secondBestDeltaW, equals(b.secondBestDeltaW));
      }
      expect(engine1.recordedCalls, equals(engine2.recordedCalls));
      expect(engine1.newGameCalls, equals(1));
      expect(engine2.newGameCalls, equals(1));
    });

    test('Brilliant allowed when MultiPV 2 second-best within 1 point is ALSO a sustained sacrifice', () async {
      const fen0 = '6k1/1p3ppp/2n5/8/8/3B4/5PPP/2R3K1 w - - 0 1';
      const fen1 = '6k1/1p3ppp/2R5/8/8/3B4/5PPP/6K1 b - - 0 1'; // after c1c6

      final w1 = WinPercent.fromCp(200);
      final w2 = WinPercent.fromCp(195); // within 1 point of line1, ALSO a sustained sac (d3h7)!

      final engine = RecordingEngineService({
        fen0: [
          EnginePvLine(
            multiPvRank: 1,
            cp: 200,
            winPercent: w1,
            moveUci: 'c1c6',
            pv: const ['c1c6', 'b7c6', 'g1f1', 'g8f8', 'f1e2'],
          ),
          EnginePvLine(
            multiPvRank: 2,
            cp: 195,
            winPercent: w2,
            moveUci: 'd3h7',
            pv: const ['d3h7', 'g8h7', 'g1f1', 'c6e5', 'f1e2'],
          ),
        ],
        fen1: [
          EnginePvLine(
            multiPvRank: 1,
            cp: -200,
            winPercent: WinPercent.fromCp(-200),
            moveUci: 'b7c6',
            pv: const ['b7c6', 'g1f1', 'g8f8', 'f1e2'],
          ),
        ],
      });

      final reviewer = GameReviewer(engine: engine, classifier: classifier);
      final review = await reviewer.reviewGame(
        initialFen: fen0,
        movesUci: ['c1c6'],
        budget: budget,
      );

      expect(review.plies.single.isSacrifice, isTrue);
      expect(review.plies.single.label, equals(ClassificationLabel.brilliant));
    });

    test('deltaW >= 10 triggers MultiPV 2 even when W_before > 90', () async {
      const fen0 = '4k3/8/8/8/8/8/5PPP/2R3K1 w - - 0 1';
      const fen1 = '4k3/8/8/8/8/8/5PPP/2R2K2 b - - 1 1';

      final engine = RecordingEngineService({
        fen0: [
          EnginePvLine(
            multiPvRank: 1,
            cp: 800, // W_before = 95% (> 90%)
            winPercent: WinPercent.fromCp(800),
            moveUci: 'c1e1',
            pv: const ['c1e1'],
          ),
          EnginePvLine(
            multiPvRank: 2,
            cp: 700,
            winPercent: WinPercent.fromCp(700),
            moveUci: 'c1c8',
            pv: const ['c1c8'],
          ),
        ],
        fen1: [
          EnginePvLine(
            multiPvRank: 1,
            cp: 0, // dropped to 50%, deltaW ~45 >= 10!
            winPercent: WinPercent.fromCp(0),
            moveUci: 'e8d7',
            pv: const ['e8d7'],
          ),
        ],
      });

      final reviewer = GameReviewer(engine: engine, classifier: classifier);
      final review = await reviewer.reviewGame(
        initialFen: fen0,
        movesUci: ['g1f1'],
        budget: budget,
      );

      expect(review.plies.single.deltaW, greaterThanOrEqualTo(10.0));
      expect(review.plies.single.usedMultiPv2, isTrue);
      expect(review.plies.single.label, equals(ClassificationLabel.blunder));
      expect(engine.recordedCalls.any((c) => c.multiPv == 2), isTrue);
    });

    test('Book is label only and still computes continuous deltaW-based accuracy', () {
      final res = classifier.classifyMove(
        playedMoveUci: 'g1f3',
        moverScoreBefore: const PositionScore(cp: 50, bestMoveUci: 'e2e4'),
        opponentScoreAfter: const PositionScore(cp: 50, bestMoveUci: 'e7e5'),
        isBook: true,
        isSacrifice: true, // even if sacrificial/gambit, Book wins first precedence
        secondBestDeltaW: 20.0,
      );

      expect(res.label, equals(ClassificationLabel.book));
      expect(res.isBook, isTrue);
      expect(res.deltaW, greaterThan(5.0));
      expect(res.accuracy, equals(MoveAccuracy.calculate(deltaW: res.deltaW)));
    });
  });
}
