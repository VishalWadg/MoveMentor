import 'package:test/test.dart';
import 'package:chess_review_core/chess_review_core.dart';

void main() {
  group('See: Basic captures & stand-pat exchanges (P1 N3 B3 R5 Q9)', () {
    test('undefended capture returns captured piece value', () {
      const fen = '4k3/8/8/3p4/8/8/8/3Q2K1 w - - 0 1';
      expect(See.evaluateCapture(fen, 'd1d5'), equals(1));
    });

    test('queen capturing defended pawn loses material (1 - 9 = -8)', () {
      const fen = '4k3/8/4p3/3p4/8/8/8/3Q2K1 w - - 0 1';
      expect(See.evaluateCapture(fen, 'd1d5'), equals(-8));
    });

    test('exchange sacrifice (Rook takes Knight defended by Pawn -> 3 - 5 = -2)', () {
      const fen = '4k3/1p6/2n5/8/8/8/8/2R3K1 w - - 0 1';
      expect(See.evaluateCapture(fen, 'c1c6'), equals(-2));
    });

    test('chain exchange stops at optimal stand-pat', () {
      // Rc5 and Qd1 attack d5 (Black pawn defended by e6 pawn)
      // Rxc5xd5 (+1), e6xd5 (-5), Qxd5 (+1) => Black stops at +5 - 1 = +4 -> White net -3
      const fen = '4k3/8/4p3/2Rp4/8/8/8/3Q2K1 w - - 0 1';
      expect(See.evaluateCapture(fen, 'c5d5'), equals(-3));
      expect(See.evaluateCapture(fen, 'd1d5'), equals(-7));
    });
  });

  group('See: Legal captures only & pins', () {
    test('evaluateCapture rejects non-captures (returns null)', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      expect(See.evaluateCapture(fen, 'e2e4'), isNull);
    });

    test('evaluateCapture rejects illegal/pinned captures (returns null)', () {
      // Black Knight on c6 is absolutely pinned by Bg2 to Ka8; cannot capture d4
      const fen = 'k7/8/2n5/8/3p4/8/6B1/3R2K1 b - - 0 1';
      expect(See.evaluateCapture(fen, 'c6d4'), isNull);
    });

    test('pinned defender cannot recapture in exchange evaluation', () {
      // White Rd1 takes d4 pawn; Black c6 Knight is pinned to Ka8 by Bg2
      // Naive SEE thinks c6xd4 (-4); legal SEE knows c6 is pinned -> +1!
      const fen = 'k7/8/2n5/8/3p4/8/6B1/3R2K1 w - - 0 1';
      expect(See.evaluateCapture(fen, 'd1d4'), equals(1));
    });

    test('pinned bishop cannot capture off pin ray, but CAN capture along pin ray', () {
      // Ka1, White Bc3 absolutely pinned by Black Qg7 along a1-h8 diagonal.
      // Black Pawn b4 (off ray, defended by Rg4) cannot be captured by Bc3 (null).
      // White a3xb4 (+1), Rg4xb4 (-1): Bc3 cannot assist off-ray -> 0.
      // Meanwhile Bc3 CAN legally capture its pinner Qg7 along the ray (9 - 3 Kxg7 = +6).
      const fen = '6k1/6q1/8/8/1p4r1/P1B5/8/K7 w - - 0 1';
      expect(See.evaluateCapture(fen, 'c3b4'), isNull);
      expect(See.evaluateCapture(fen, 'a3b4'), equals(0));
      expect(See.evaluateCapture(fen, 'c3g7'), equals(6));
    });
  });

  group('See: X-ray attackers & defenders', () {
    test('rook battery uncovers x-ray defender on same file', () {
      // e4 Rook takes e5 Pawn, defended by Re6 + x-ray Re8; White has Re1 behind Re4
      // e4e5 (+1), e6e5 (-5), e1e5 (+5), e8e5 (-5) => net -4
      const fen = 'k3r3/8/4r3/4p3/4R3/8/8/4R1K1 w - - 0 1';
      expect(See.evaluateCapture(fen, 'e4e5'), equals(-4));
    });

    test('queen x-rays through bishop after bishop moves, preventing illegal King capture', () {
      // White Bc4 with Qb3 behind on b3-c4-d5-e6-f7 diagonal; Black Pawn on f7, King on e8
      // Bxf7+ moves Bc4 leaving Qb3 x-raying f7, so Kxf7 is illegal -> SEE = +1!
      const fen = '4k3/5p2/8/8/2B5/1Q6/8/6K1 w - - 0 1';
      expect(See.evaluateCapture(fen, 'c4f7'), equals(1));
    });

    test('equal-value N vs B tie explores hidden X-ray battery behind Bishop', () {
      // Black Rook on d5 (5) defended by Nf6 (3) and Rd8 (5).
      // White has Nf4 (3), Bc4 (3), and Qb3 (9, hidden X-ray behind Bc4 on b3-c4-d5).
      // Tied at min attacker value 3 (Nf4 and Bc4): best legal sequence captures Rook cleanly (+5).
      const fen = '3r2k1/8/5n2/3r4/2B2N2/1Q6/8/6K1 w - - 0 1';
      expect(See.evaluateSquareCapture(fen, 'd5'), equals(5));
    });
  });

  group('See: En passant captures & pins', () {
    test('en passant captures pawn on fifth rank and lands on ep square (undefended -> +1)', () {
      const fen = '4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1';
      expect(See.evaluateCapture(fen, 'e5d6'), equals(1));
    });

    test('en passant recaptured on landing square d6 by c7 pawn (+1 - 1 = 0)', () {
      const fen = '4k3/2p5/8/3pP3/8/8/8/4K3 w - d6 0 1';
      expect(See.evaluateCapture(fen, 'e5d6'), equals(0));
    });

    test('horizontal en passant pin makes capture illegal (returns null)', () {
      // White Ka5, Black d5 pawn, White e5 pawn, Black Rh5 -> e5d6 exposes Ka5 to Rh5!
      const fen = '8/8/8/K2pP2r/8/8/8/4k3 w - d6 0 1';
      expect(See.evaluateCapture(fen, 'e5d6'), isNull);
    });
  });

  group('See: Promotions', () {
    test('undefended capture-promotion to Queen adds +8 promotion bonus (5 + 8 = +13)', () {
      // Black King on g8 (cannot recapture on d8)
      const fen = '3r2k1/2P5/8/8/8/8/8/4K3 w - - 0 1';
      expect(See.evaluateCapture(fen, 'c7d8q'), equals(13));
      expect(See.evaluateCapture(fen, 'c7d8n'), equals(7));
    });

    test('defended capture-promotion to Queen nets captured minus 1 pawn (+5 + 8 - 9 = +4)', () {
      // Black d8 Rook defended by b8 Queen
      const fen = '1q1r2k1/2P5/8/8/8/8/8/4K3 w - - 0 1';
      expect(See.evaluateCapture(fen, 'c7d8q'), equals(4));
    });

    test('promotion occurs mid-exchange during recaptures on back rank', () {
      // White Re1 + d7 Pawn vs Black Knight on e8 defended by Ra8 (5) and Qh5 (9).
      // Rxe8 (+3), Ra8xe8 (-5), dxe8=Q (+13), Qh5xe8 (-9) => net +2
      const fen = 'r3n1k1/3P4/8/7q/8/8/8/4R1K1 w - - 0 1';
      expect(See.evaluateCapture(fen, 'e1e8'), equals(2));
    });

    test('quiet promotion push onto defended square via evaluateMove (0 + 8 - 9 = -1)', () {
      const fen = 'r5k1/4P3/8/8/8/8/8/4K3 w - - 0 1';
      expect(See.evaluateCapture(fen, 'e7e8q'), isNull);
      expect(See.evaluateMove(fen, 'e7e8q'), equals(-1));
    });
  });

  group('See: Sustained sacrifice along PV vs temporary tactic', () {
    test('accepted exchange sacrifice sustained along PV returns true', () {
      // Rxc6 bxc6 -> White remains -2 along PV
      const fenBefore = '4k3/1p6/2n5/8/8/8/8/2R3K1 w - - 0 1';
      const fenAfter = '4k3/1p6/2R5/8/8/8/8/6K1 b - - 0 1';
      final sustained = See.isSacrificeSustainedAlongPv(
        fenBefore: fenBefore,
        fenAfter: fenAfter,
        playedMoveUci: 'c1c6',
        pvAfter: const ['b7c6', 'g1f2', 'e8d7', 'f2e3'],
      );
      expect(sustained, isTrue);
    });

    test('pseudo-sacrifice recovering material on move 2 of PV returns false', () {
      // Suppose White plays Rxe8-style or Rxc6 bxc6 followed immediately by Qxd8 winning Queen
      // Black King on e8, Black Queen on d8, Black Knight on c6, Black Pawn on b7, White Rc1, White Qd1 -> Wait: put Qd1 on open d-file (Rd1 vs Qd8) + Rc1xd6?
      // Position: 3qk3/1p6/2n5/8/8/8/8/2RR2K1 w - - 0 1
      // Wait: if White plays c1c6 (Rxc6), and somehow PV recovers: e.g. b7c6 is forced? Not forced, just hypothetical PV ['b7c6', 'd1d8']
      // Put c1c6 taking c6(N=3), followed by Black b7c6 (-5), then White d1d8 (+9) => net +7!
      const fenBefore = '3qk3/1p6/2n5/8/8/8/8/2RR2K1 w - - 0 1';
      const fenAfter = '3qk3/1p6/2R5/8/8/8/8/3R2K1 b - - 0 1';
      final sustained = See.isSacrificeSustainedAlongPv(
        fenBefore: fenBefore,
        fenAfter: fenAfter,
        playedMoveUci: 'c1c6',
        pvAfter: const ['b7c6', 'd1d8'],
      );
      expect(sustained, isFalse);
    });
  });
}
