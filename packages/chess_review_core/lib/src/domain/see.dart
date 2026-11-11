import 'dart:math' as math;
import 'package:chess/chess.dart' as ch;

/// Pure-Dart Static Exchange Evaluation (SEE) and tactical board helpers.
///
/// SPEC RULES:
/// - Piece values: P=1, N=3, B=3, R=5, Q=9 (K=1000 sentinel).
/// - Legal captures only: excludes pinned attackers/defenders and illegal
///   king captures (including X-ray defended squares and horizontal ep pins).
/// - Handles pins, X-rays, en passant captures, and promotions (both initial
///   and intermediate recaptures).
abstract final class See {
  static const int kPawnValue = 1;
  static const int kKnightValue = 3;
  static const int kBishopValue = 3;
  static const int kRookValue = 5;
  static const int kQueenValue = 9;
  static const int kKingValue = 1000;

  /// Standard material point values per the authoritative specification.
  static int valueOf(ch.PieceType? type) {
    if (type == null) return 0;
    if (type == ch.PieceType.PAWN) return kPawnValue;
    if (type == ch.PieceType.KNIGHT) return kKnightValue;
    if (type == ch.PieceType.BISHOP) return kBishopValue;
    if (type == ch.PieceType.ROOK) return kRookValue;
    if (type == ch.PieceType.QUEEN) return kQueenValue;
    if (type == ch.PieceType.KING) return kKingValue;
    return 0;
  }

  /// Immediate material gain of executing [move], including promotion delta.
  static int _moveGain(ch.Move move) {
    final capVal = _isCapture(move) ? valueOf(move.captured ?? ch.PieceType.PAWN) : 0;
    final promoDelta =
        move.promotion != null ? (valueOf(move.promotion) - kPawnValue) : 0;
    return capVal + promoDelta;
  }

  static bool _isCapture(ch.Move move) {
    return move.captured != null ||
        (move.flags & ch.Chess.BITS_EP_CAPTURE) != 0;
  }

  /// Converts a [ch.Move] to lowercase UCI notation (e.g. "e2e4", "e7e8q").
  static String moveToUci(ch.Move move) {
    return '${move.fromAlgebraic}${move.toAlgebraic}${move.promotion?.name ?? ''}'
        .toLowerCase();
  }

  /// Finds matching legal move for [moveUci] in [game], or returns null.
  static ch.Move? findLegalMove(ch.Chess game, String moveUci) {
    final target = moveUci.trim().toLowerCase();
    for (final m in game.generate_moves()) {
      if (moveToUci(m) == target) {
        return m;
      }
    }
    return null;
  }

  /// Evaluates Static Exchange Evaluation for a **legal capture** [moveUci] from [fen].
  ///
  /// Strictly rejects non-captures and illegal moves (e.g. pinned pieces attempting
  /// capture, horizontal en passant pins) by returning `null`.
  static int? evaluateCapture(String fen, String moveUci) {
    final game = ch.Chess.fromFEN(fen);
    final move = findLegalMove(game, moveUci);
    if (move == null || !_isCapture(move)) {
      return null;
    }
    return _evaluateLegalMoveInternal(game, move);
  }

  /// Evaluates Static Exchange Evaluation for any **legal move** [moveUci] from [fen]
  /// (captures, promotions, or quiet moves onto an attacked square).
  ///
  /// Returns `null` if [moveUci] is not legal in [fen].
  static int? evaluateMove(String fen, String moveUci) {
    final game = ch.Chess.fromFEN(fen);
    final move = findLegalMove(game, moveUci);
    if (move == null) {
      return null;
    }
    return _evaluateLegalMoveInternal(game, move);
  }

  static int _evaluateLegalMoveInternal(ch.Chess game, ch.Move move) {
    final initialGain = _moveGain(move);
    final targetSq = move.to;
    game.make_move(move);
    final opponentBestGain = _seeMaxGainOnSquare(game, targetSq);
    game.undo_move();
    return initialGain - opponentBestGain;
  }

  /// Evaluates the best legal capture SEE onto [targetSquare] (e.g. `"d5"`)
  /// for the side currently to move in [fen]. Returns >= 0 (stand pat floor 0).
  static int evaluateSquareCapture(String fen, String targetSquare) {
    final game = ch.Chess.fromFEN(fen);
    final sqIndex = ch.Chess.SQUARES[targetSquare.toLowerCase()];
    if (sqIndex == null) return 0;
    return _seeMaxGainOnSquare(game, sqIndex);
  }

  /// Recursive legal-capture negamax SEE onto [targetSquare] (side to move may stand pat = 0).
  static int _seeMaxGainOnSquare(ch.Chess game, int targetSquare) {
    final allCaptures = game.generate_moves().where((m) {
      if (m.to != targetSquare || !_isCapture(m)) return false;
      // During material exchange recaptures, promoting to Queen dominates all underpromotions.
      if (m.promotion != null && m.promotion != ch.PieceType.QUEEN) {
        return false;
      }
      return true;
    }).toList();

    if (allCaptures.isEmpty) return 0;

    // Identify the minimum risked piece value (LVA: P < N=B < R < Q < K).
    // Even if a pawn promotes, it only risks 1 net pawn unit if recaptured.
    var minRiskedValue = kKingValue + 1;
    for (final m in allCaptures) {
      final val = valueOf(m.piece);
      if (val < minRiskedValue) {
        minRiskedValue = val;
      }
    }

    // Explore all legal captures tied at minimum attacker value to handle
    // X-ray batteries uncovered by equal-value pieces (e.g. N vs B on the same square).
    final bestCandidates =
        allCaptures.where((m) => valueOf(m.piece) == minRiskedValue).toList();

    var bestGain = 0; // Stand pat = 0
    for (final cand in bestCandidates) {
      final gain = _moveGain(cand);
      game.make_move(cand);
      final replyGain = _seeMaxGainOnSquare(game, targetSquare);
      game.undo_move();
      bestGain = math.max(bestGain, gain - replyGain);
    }

    return bestGain;
  }

  /// Computes net material balance for [side] (mover minus opponent),
  /// using P=1, N=3, B=3, R=5, Q=9 (kings excluded).
  static int materialBalance(String fen, ch.Color side) {
    final game = ch.Chess.fromFEN(fen);
    return materialBalanceFromBoard(game, side);
  }

  /// Computes net material balance from an active [ch.Chess] board state.
  static int materialBalanceFromBoard(ch.Chess game, ch.Color side) {
    var whitePts = 0;
    var blackPts = 0;
    for (var i = 0; i < 128; i++) {
      if ((i & 0x88) != 0) continue;
      final piece = game.board[i];
      if (piece == null || piece.type == ch.PieceType.KING) continue;
      final pts = valueOf(piece.type);
      if (piece.color == ch.Color.WHITE) {
        whitePts += pts;
      } else {
        blackPts += pts;
      }
    }
    return side == ch.Color.WHITE ? (whitePts - blackPts) : (blackPts - whitePts);
  }

  /// Determines whether [moveUci] from [fenBefore] is a recapture of the
  /// opponent's immediately preceding capture on [previousMoveToSquare].
  static bool isRecaptureMove({
    required String fenBefore,
    required String moveUci,
    required bool previousMoveWasCapture,
    required String? previousMoveToSquare,
  }) {
    if (!previousMoveWasCapture || previousMoveToSquare == null) {
      return false;
    }
    final game = ch.Chess.fromFEN(fenBefore);
    final move = findLegalMove(game, moveUci);
    if (move == null || !_isCapture(move)) {
      return false;
    }
    return move.toAlgebraic.toLowerCase() == previousMoveToSquare.toLowerCase();
  }

  /// Checks if [playedMoveUci] is a real sacrifice:
  /// 1. Real SEE <= [seeThreshold] (default -2 points: P1 N3 B3 R5 Q9), AND
  /// 2. Material deficit <= [seeThreshold] is sustained along [pvAfter]
  ///    (i.e. opponent captures and mover does not immediately win material
  ///    back within [maxPvPlies]).
  static bool isSacrificeSustainedAlongPv({
    required String fenBefore,
    required String fenAfter,
    required String playedMoveUci,
    required List<String> pvAfter,
    int seeThreshold = -2,
    int maxPvPlies = 4,
  }) {
    final see = evaluateMove(fenBefore, playedMoveUci);
    if (see == null || see > seeThreshold) {
      return false;
    }

    // Must have continuation moves in PV to verify the sacrifice is sustained.
    if (pvAfter.isEmpty) {
      return false;
    }

    final beforeGame = ch.Chess.fromFEN(fenBefore);
    final moverColor = beforeGame.turn;
    final initialBalance = materialBalanceFromBoard(beforeGame, moverColor);

    final simGame = ch.Chess.fromFEN(fenAfter);
    final pliesToCheck = math.min(pvAfter.length, maxPvPlies);

    var deficitSeenInPv = false;
    var lastBalanceDelta =
        materialBalanceFromBoard(simGame, moverColor) - initialBalance;

    for (var i = 0; i < pliesToCheck; i++) {
      final pvMove = findLegalMove(simGame, pvAfter[i]);
      if (pvMove == null) {
        return false;
      }
      simGame.make_move(pvMove);
      lastBalanceDelta =
          materialBalanceFromBoard(simGame, moverColor) - initialBalance;
      if (lastBalanceDelta <= seeThreshold) {
        deficitSeenInPv = true;
      }
    }

    // Sacrifice is sustained only if a >= 2-point deficit actually materialized
    // in the PV and remains <= seeThreshold at the end of the checked PV window.
    return deficitSeenInPv && lastBalanceDelta <= seeThreshold;
  }
}
