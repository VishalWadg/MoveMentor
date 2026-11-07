import 'package:chess/chess.dart' as ch;
import 'package:flutter/material.dart';
import '../../domain/chess/chess_models.dart';
export '../features/review/eval_graph_widget.dart';

/// Part 19-11 & Story F-4 AC3: Original move-classification badge set relying on
/// distinct shape + icon + text (never colour alone, and never Chess.com glyphs).
class MoveBadgeChip extends StatelessWidget {
  final MoveClassification classification;
  final bool compact;

  const MoveBadgeChip({
    super.key,
    required this.classification,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final spec = _badgeSpec(classification);
    return Semantics(
      label: 'Move classification: ${classification.label}',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 10,
          vertical: compact ? 2 : 4,
        ),
        decoration: BoxDecoration(
          color: spec.bgColor,
          borderRadius: BorderRadius.circular(spec.borderRadius),
          border: Border.all(color: spec.fgColor, width: 1.4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(spec.icon, size: compact ? 13 : 16, color: spec.fgColor),
            const SizedBox(width: 4),
            Text(
              compact ? spec.shortText : classification.label,
              style: TextStyle(
                color: spec.fgColor,
                fontWeight: FontWeight.w700,
                fontSize: compact ? 11 : 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static _BadgeVisualSpec _badgeSpec(MoveClassification c) {
    switch (c) {
      case MoveClassification.brilliant:
        return const _BadgeVisualSpec(
          icon: Icons.auto_awesome,
          shortText: 'BRIL',
          fgColor: Color(0xFF004D40),
          bgColor: Color(0xFFE0F2F1),
          borderRadius: 14,
        );
      case MoveClassification.great:
        return const _BadgeVisualSpec(
          icon: Icons.star_rounded,
          shortText: 'GREAT',
          fgColor: Color(0xFF0D47A1),
          bgColor: Color(0xFFE3F2FD),
          borderRadius: 12,
        );
      case MoveClassification.best:
        return const _BadgeVisualSpec(
          icon: Icons.check_circle_outline,
          shortText: 'BEST',
          fgColor: Color(0xFF1B5E20),
          bgColor: Color(0xFFE8F5E9),
          borderRadius: 10,
        );
      case MoveClassification.excellent:
        return const _BadgeVisualSpec(
          icon: Icons.thumb_up_alt_outlined,
          shortText: 'EXCL',
          fgColor: Color(0xFF2E7D32),
          bgColor: Color(0xFFF1F8E9),
          borderRadius: 8,
        );
      case MoveClassification.good:
        return const _BadgeVisualSpec(
          icon: Icons.check,
          shortText: 'GOOD',
          fgColor: Color(0xFF37474F),
          bgColor: Color(0xFFECEFF1),
          borderRadius: 8,
        );
      case MoveClassification.book:
        return const _BadgeVisualSpec(
          icon: Icons.menu_book_rounded,
          shortText: 'BOOK',
          fgColor: Color(0xFF4E342E),
          bgColor: Color(0xFFEFEBE9),
          borderRadius: 6,
        );
      case MoveClassification.inaccuracy:
        return const _BadgeVisualSpec(
          icon: Icons.info_outline,
          shortText: 'INAC',
          fgColor: Color(0xFFE65100),
          bgColor: Color(0xFFFFF3E0),
          borderRadius: 4,
        );
      case MoveClassification.mistake:
        return const _BadgeVisualSpec(
          icon: Icons.warning_amber_rounded,
          shortText: 'MIST',
          fgColor: Color(0xFFBF360C),
          bgColor: Color(0xFFFBE9E7),
          borderRadius: 4,
        );
      case MoveClassification.blunder:
        return const _BadgeVisualSpec(
          icon: Icons.report_problem_rounded,
          shortText: 'BLND',
          fgColor: Color(0xFFB71C1C),
          bgColor: Color(0xFFFFEBEE),
          borderRadius: 2,
        );
    }
  }
}

class _BadgeVisualSpec {
  final IconData icon;
  final String shortText;
  final Color fgColor;
  final Color bgColor;
  final double borderRadius;

  const _BadgeVisualSpec({
    required this.icon,
    required this.shortText,
    required this.fgColor,
    required this.bgColor,
    required this.borderRadius,
  });
}

/// Story F-1 & F-2 & NFR-10: Interactive ChessBoard Widget with:
/// - TalkBack/VoiceOver screen-reader labels on every square ("White knight on f3")
/// - Last-move highlight
/// - Engine best-move arrow overlay
/// - Flip control support
class InteractiveChessBoard extends StatelessWidget {
  final String fen;
  final bool flipped;
  final String? lastMoveUci;
  final String? bestMoveUci;
  final void Function(String fromSq, String toSq)? onMoveTapped;

  const InteractiveChessBoard({
    super.key,
    required this.fen,
    this.flipped = false,
    this.lastMoveUci,
    this.bestMoveUci,
    this.onMoveTapped,
  });

  static const Map<String, String> _unicodePieces = {
    'wk': '♔',
    'wq': '♕',
    'wr': '♖',
    'wb': '♗',
    'wn': '♘',
    'wp': '♙',
    'bk': '♚',
    'bq': '♛',
    'br': '♜',
    'bb': '♝',
    'bn': '♞',
    'bp': '♟',
  };

  @override
  Widget build(BuildContext context) {
    final game = ch.Chess.fromFEN(fen);
    final lastFrom =
        lastMoveUci != null && lastMoveUci!.length >= 4 ? lastMoveUci!.substring(0, 2) : null;
    final lastTo =
        lastMoveUci != null && lastMoveUci!.length >= 4 ? lastMoveUci!.substring(2, 4) : null;

    return AspectRatio(
      aspectRatio: 1.0,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final boardSize = constraints.maxWidth;
          final sqSize = boardSize / 8.0;

          return Stack(
            children: [
              GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 64,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 8,
                ),
                itemBuilder: (context, index) {
                  final row = index ~/ 8;
                  final col = index % 8;
                  final rankIdx = flipped ? (7 - row) : row;
                  final fileIdx = flipped ? (7 - col) : col;
                  final sq0x88 = rankIdx * 16 + fileIdx;
                  final alg = ch.Chess.algebraic(sq0x88);
                  final piece = game.board[sq0x88];

                  final isLight = (rankIdx + fileIdx).isEven;
                  final isHighlighted = alg == lastFrom || alg == lastTo;

                  // Original MoveMentor Slate & Warm Sand board palette (Part 19-11)
                  final baseColor = isLight
                      ? const Color(0xFFF3EFE6)
                      : const Color(0xFF5B7083);
                  final sqColor = isHighlighted
                      ? const Color(0xFFFFE082)
                      : baseColor;

                  final semanticLabel = _buildSquareSemantics(alg, piece);
                  final glyph = piece != null
                      ? _unicodePieces[
                          '${piece.color == ch.Color.WHITE ? "w" : "b"}${piece.type.name.toLowerCase()}']
                      : null;

                  return Semantics(
                    label: semanticLabel,
                    button: true,
                    child: GestureDetector(
                      key: ValueKey('board_sq_$alg'),
                      onTap: () {
                        if (onMoveTapped != null && bestMoveUci != null && bestMoveUci!.length >= 4) {
                          onMoveTapped!(
                            bestMoveUci!.substring(0, 2),
                            bestMoveUci!.substring(2, 4),
                          );
                        }
                      },
                      child: Container(
                        color: sqColor,
                        alignment: Alignment.center,
                        child: Stack(
                          children: [
                            if (col == 0)
                              Positioned(
                                top: 2,
                                left: 3,
                                child: Text(
                                  '${8 - rankIdx}',
                                  textScaler: TextScaler.noScaling,
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: isLight
                                        ? const Color(0xFF5B7083)
                                        : const Color(0xFFF3EFE6),
                                  ),
                                ),
                              ),
                            if (row == 7)
                              Positioned(
                                bottom: 2,
                                right: 3,
                                child: Text(
                                  String.fromCharCode('a'.codeUnitAt(0) + fileIdx),
                                  textScaler: TextScaler.noScaling,
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: isLight
                                        ? const Color(0xFF5B7083)
                                        : const Color(0xFFF3EFE6),
                                  ),
                                ),
                              ),
                            if (glyph != null)
                              Center(
                                child: Text(
                                  glyph,
                                  textScaler: TextScaler.noScaling,
                                  style: TextStyle(
                                    fontSize: sqSize * 0.68,
                                    height: 1.0,
                                    color: piece!.color == ch.Color.WHITE
                                        ? const Color(0xFF1A1A1A)
                                        : const Color(0xFF0D1B2A),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (bestMoveUci != null && bestMoveUci!.length >= 4)
                IgnorePointer(
                  child: CustomPaint(
                    size: Size(boardSize, boardSize),
                    painter: _BestMoveArrowPainter(
                      fromAlg: bestMoveUci!.substring(0, 2),
                      toAlg: bestMoveUci!.substring(2, 4),
                      flipped: flipped,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Story F-1 AC1 & NFR-10: Screen-reader label ("White knight on f3" or "Empty square e4").
  static String _buildSquareSemantics(String alg, ch.Piece? piece) {
    if (piece == null) return 'Empty square $alg';
    final colorWord = piece.color == ch.Color.WHITE ? 'White' : 'Black';
    String pieceWord;
    switch (piece.type) {
      case ch.PieceType.KING:
        pieceWord = 'king';
        break;
      case ch.PieceType.QUEEN:
        pieceWord = 'queen';
        break;
      case ch.PieceType.ROOK:
        pieceWord = 'rook';
        break;
      case ch.PieceType.BISHOP:
        pieceWord = 'bishop';
        break;
      case ch.PieceType.KNIGHT:
        pieceWord = 'knight';
        break;
      default:
        pieceWord = 'pawn';
    }
    return '$colorWord $pieceWord on $alg';
  }
}

class _BestMoveArrowPainter extends CustomPainter {
  final String fromAlg;
  final String toAlg;
  final bool flipped;

  const _BestMoveArrowPainter({
    required this.fromAlg,
    required this.toAlg,
    required this.flipped,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p1 = _squareCenter(fromAlg, size);
    final p2 = _squareCenter(toAlg, size);
    if (p1 == null || p2 == null) return;

    final paint = Paint()
      ..color = const Color(0xCC00897B)
      ..strokeWidth = size.width * 0.028
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(p1, p2, paint);
    canvas.drawCircle(p2, size.width * 0.038, paint);
  }

  Offset? _squareCenter(String alg, Size size) {
    if (alg.length < 2) return null;
    final file = alg.codeUnitAt(0) - 'a'.codeUnitAt(0);
    final rank = int.tryParse(alg[1]);
    if (file < 0 || file > 7 || rank == null || rank < 1 || rank > 8) {
      return null;
    }
    final row = 8 - rank;
    final col = file;
    final drawRow = flipped ? (7 - row) : row;
    final drawCol = flipped ? (7 - col) : col;
    final sq = size.width / 8.0;
    return Offset((drawCol + 0.5) * sq, (drawRow + 0.5) * sq);
  }

  @override
  bool shouldRepaint(covariant _BestMoveArrowPainter oldDelegate) =>
      oldDelegate.fromAlg != fromAlg ||
      oldDelegate.toAlg != toAlg ||
      oldDelegate.flipped != flipped;
}

