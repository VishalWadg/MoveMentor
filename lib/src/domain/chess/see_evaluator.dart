import 'package:chess/chess.dart' as ch;

/// Piece values per Part 24: P=1, N=3, B=3, R=5, Q=9, K=100.
class SeeEvaluator {
  static const Map<String, int> piecePoints = {
    'p': 1,
    'n': 3,
    'b': 3,
    'r': 5,
    'q': 9,
    'k': 100,
  };

  static int valueOf(ch.Piece? p) {
    if (p == null) return 0;
    return piecePoints[p.type.name.toLowerCase()] ?? 0;
  }

  static String pieceFullName(String typeChar) {
    switch (typeChar.toLowerCase()) {
      case 'p':
        return 'pawn';
      case 'n':
        return 'knight';
      case 'b':
        return 'bishop';
      case 'r':
        return 'rook';
      case 'q':
        return 'queen';
      case 'k':
        return 'king';
      default:
        return 'piece';
    }
  }

  /// Combined non-pawn, non-king material of both sides (Part 19-3: Endgame <= 13).
  static int combinedNonPawnMaterial(String fen) {
    final boardPart = fen.split(' ').first;
    var total = 0;
    for (final chCode in boardPart.split('')) {
      switch (chCode.toLowerCase()) {
        case 'n':
        case 'b':
          total += 3;
          break;
        case 'r':
          total += 5;
          break;
        case 'q':
          total += 9;
          break;
      }
    }
    return total;
  }

  /// Net material balance from mover's perspective (mover material - opponent material).
  static int materialBalanceForSide(String fen, String sideColor) {
    final boardPart = fen.split(' ').first;
    var whitePts = 0;
    var blackPts = 0;
    for (final c in boardPart.split('')) {
      final pts = piecePoints[c.toLowerCase()] ?? 0;
      if (pts == 0 || pts == 100) continue;
      if (c == c.toUpperCase()) {
        whitePts += pts;
      } else {
        blackPts += pts;
      }
    }
    return sideColor == 'w' ? (whitePts - blackPts) : (blackPts - whitePts);
  }

  /// Static Exchange Evaluation (SEE) on `targetSquare` for the side currently to move in `fen`.
  /// Uses legal captures only (avoiding pinned-attacker and pinned-defender traps per Part 24).
  static int evaluateBestCaptureSee(String fen, String targetSquare) {
    final game = ch.Chess.fromFEN(fen);
    final legalCaptures = game
        .generate_moves()
        .where((m) => m.toAlgebraic == targetSquare && (m.captured != null))
        .toList();
    if (legalCaptures.isEmpty) return 0;

    // Sort by least valuable attacker first
    legalCaptures.sort(
      (a, b) => (piecePoints[a.piece.name.toLowerCase()] ?? 1)
          .compareTo(piecePoints[b.piece.name.toLowerCase()] ?? 1),
    );

    final chosen = legalCaptures.first;
    final capturedValue = piecePoints[chosen.captured!.name.toLowerCase()] ?? 0;
    game.move(chosen);
    final replySee = _seeRecursive(game, targetSquare);
    return capturedValue - (replySee > 0 ? replySee : 0);
  }

  static int _seeRecursive(ch.Chess game, String square) {
    final captures = game
        .generate_moves()
        .where((m) => m.toAlgebraic == square && m.captured != null)
        .toList();
    if (captures.isEmpty) return 0;
    captures.sort(
      (a, b) => (piecePoints[a.piece.name.toLowerCase()] ?? 1)
          .compareTo(piecePoints[b.piece.name.toLowerCase()] ?? 1),
    );
    final move = captures.first;
    final val = piecePoints[move.captured!.name.toLowerCase()] ?? 0;
    game.move(move);
    final nextGain = _seeRecursive(game, square);
    final score = val - (nextGain > 0 ? nextGain : 0);
    game.undo_move();
    return score > 0 ? score : 0;
  }

  /// Evaluates SEE of a specific played move from `fenBefore`.
  /// Negative return value means the move sacrifices material on the destination square.
  static int seeOfMove(String fenBefore, String moveSanOrUci) {
    final game = ch.Chess.fromFEN(fenBefore);
    final moves = game.generate_moves();
    ch.Move? targetMove;
    for (final m in moves) {
      final san = game.move_to_san(m);
      final uci = '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}';
      if (san == moveSanOrUci || uci == moveSanOrUci) {
        targetMove = m;
        break;
      }
    }
    if (targetMove == null) return 0;
    final gained = targetMove.captured != null
        ? (piecePoints[targetMove.captured!.name.toLowerCase()] ?? 0)
        : 0;
    final destSquare = targetMove.toAlgebraic;
    game.move(targetMove);
    final opponentGain = evaluateBestCaptureSee(game.fen, destSquare);
    return gained - (opponentGain > 0 ? opponentGain : 0);
  }
}
