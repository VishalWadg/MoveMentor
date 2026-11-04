import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/domain/chess/chess_models.dart';
import 'package:movementor/src/domain/chess/fen_normalizer.dart';
import 'package:movementor/src/domain/chess/pgn_parser.dart';
import 'package:movementor/src/domain/tags/tag_detector.dart';

void main() {
  group('Part 26.5 PGN Parser Corpus & Part 24 Tag Rules', () {
    test('T-IMP-01..02: Multi-game PGN, comments, variations, promotion without =, illegal move prefix', () {
      const messyPgn = '''
[Event "Game 1"]
[White "Alice"]
[Black "Bob"]
[Result "1-0"]

1. e4 { [%clk 0:09:58] } e5 (1... c5 2. Nf3) 2. Nf3 $1 Nc6 0-0 1-0

[Event "Chess960 Game"]
[Variant "Chess960"]
[White "C"]
[Black "D"]
[Result "*"]

1. e4 e5 *
''';
      final report = PgnParser.parseMultiGamePgn(messyPgn);
      expect(report.games.length, 2);
      // First game has illegal castling 0-0 on move 3 before bishop moves -> marked partially_valid
      expect(report.games[0].game.status, 'partially_valid');
      expect(report.games[0].errorCode, 'E-IMP-06');
      expect(report.games[0].game.movesSan.length, 4);
      expect(report.games[0].clocksMs[1], 598000);

      // Second game is Chess960 -> stored, marked not_analysable (E-IMP-08)
      expect(report.games[1].game.status, 'not_analysable');
      expect(report.games[1].errorCode, 'E-IMP-08');
    });

    test('Part 21 & 25: FEN normalizer drops fake en-passant and SanWords converts SAN', () {
      // e6 en-passant square with no white pawn on d5/f5 should be normalized to '-'
      const fenFakeEp =
          'rnbqkbnr/pppp1ppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2';
      expect(
        FenNormalizer.normaliseFen(fenFakeEp),
        'rnbqkbnr/pppp1ppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -',
      );

      expect(SanWords.sanToWords('Nf3'), 'Knight to f3');
      expect(SanWords.sanToWords('Qxb7+'), 'Queen captures on b7 with check');
      expect(SanWords.sanToWords('O-O'), 'castling kingside');
      expect(
        SanWords.sanToWords('e8=Q#'),
        'Pawn to e8 promoting to Queen delivering checkmate',
      );
    });

    test('Part 24: Hanging piece detector identifies undefended queen after Qxb7', () {
      const fenBefore =
          '1rbqkbnr/p1pp1ppp/2n5/4p3/4P3/1Q3N2/PPPP1PPP/RNB1KB1R w KQkq - 1 5';
      const fenAfterQxb7 =
          '1rbqkbnr/pQpp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNB1KB1R b KQkq - 0 5';
      final tags = TagDetector.detectTagsForMoment(
        gameId: 'g1',
        ply: 9,
        fenBefore: fenBefore,
        fenAfterPlayed: fenAfterQxb7,
        playedMoveSan: 'Qxb7',
        bestMoveUci: 'f1c4',
        phase: GamePhase.opening,
      );
      expect(tags.any((t) => t.code == 'HANGING_PIECE'), isTrue);
      final hp = tags.firstWhere((t) => t.code == 'HANGING_PIECE');
      expect(hp.params['piece'], 'queen');
      expect(hp.params['square'], 'b7');
    });
  });
}
