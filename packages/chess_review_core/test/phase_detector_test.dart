import 'package:test/test.dart';
import 'package:chess_review_core/chess_review_core.dart';

void main() {
  group('PhaseDetector heuristics (Endgame <= 13, else Opening <= 24 or book, else Middlegame)', () {
    test('material count sums non-pawn non-king pieces (N3 B3 R5 Q9)', () {
      // Starting position: 2*(2*3 + 2*3 + 2*5 + 9) = 2*(6 + 6 + 10 + 9) = 62
      const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      expect(PhaseDetector.combinedNonPawnNonKingMaterial(startFen), equals(62));

      // K+Q+N (9+3) vs K (0) = 12 <= 13 -> Endgame
      const qnEndgame = '4k3/8/8/8/8/8/8/4KQ1N w - - 0 1';
      expect(PhaseDetector.combinedNonPawnNonKingMaterial(qnEndgame), equals(12));

      // K+R+R (5+5) vs K+N (3) = 13 <= 13 -> Endgame boundary
      const exact13 = '4k2n/8/8/8/8/8/8/R3K2R w - - 0 1';
      expect(PhaseDetector.combinedNonPawnNonKingMaterial(exact13), equals(13));

      // K+R+R (5+5) vs K+R (5) = 15 > 13 -> NOT Endgame
      const above13 = '4k2r/8/8/8/8/8/8/R3K2R w - - 0 1';
      expect(PhaseDetector.combinedNonPawnNonKingMaterial(above13), equals(15));
    });

    test('Endgame threshold <= 13 overrides ply <= 24 and isBook', () {
      const material13Fen = '4k2n/8/8/8/8/8/8/R3K2R w - - 0 1';
      expect(
        PhaseDetector.detect(fen: material13Fen, ply: 5, isBook: true),
        equals(GamePhase.endgame),
      );
      expect(
        PhaseDetector.detect(fen: material13Fen, ply: 24, isBook: false),
        equals(GamePhase.endgame),
      );
    });

    test('boundary material == 14 is Opening when ply <= 24 or book, else Middlegame', () {
      // K+R (5) + N (3) vs K+N (3) + B (3) = 14
      const material14Fen = '4k1nb/8/8/8/8/8/8/R3K2N w - - 0 1';
      expect(PhaseDetector.combinedNonPawnNonKingMaterial(material14Fen), equals(14));

      expect(
        PhaseDetector.detect(fen: material14Fen, ply: 24, isBook: false),
        equals(GamePhase.opening),
      );
      expect(
        PhaseDetector.detect(fen: material14Fen, ply: 25, isBook: false),
        equals(GamePhase.middlegame),
      );
      expect(
        PhaseDetector.detect(fen: material14Fen, ply: 30, isBook: true),
        equals(GamePhase.opening),
      );
    });

    test('ply == 0 or pawns-only position handles safely', () {
      const kpOnly = '4k3/4p3/8/8/8/8/4P3/4K3 w - - 0 1';
      expect(PhaseDetector.combinedNonPawnNonKingMaterial(kpOnly), equals(0));
      expect(
        PhaseDetector.detect(fen: kpOnly, ply: 0, isBook: false),
        equals(GamePhase.endgame),
      );
    });
  });
}
