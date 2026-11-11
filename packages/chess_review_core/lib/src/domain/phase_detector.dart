/// Game phase categories used for per-phase accuracy aggregation.
enum GamePhase {
  opening,
  middlegame,
  endgame,
}

/// Heuristic game phase detector.
///
/// SPEC RULES:
/// - Endgame if combined non-pawn, non-king material <= 13 (N=3, B=3, R=5, Q=9).
/// - Else Opening if ply <= 24 or position is in the opening book.
/// - Else Middlegame.
///
/// LIMITATIONS (documented per specification):
/// This lightweight heuristic relies solely on piece material sum, ply index,
/// and book membership. It intentionally ignores queenless complex structures,
/// king safety/activity, pawn structure, and imbalanced endgames where total
/// non-pawn material slightly exceeds 13 (e.g., Q+R vs Q+B+N = 20).
abstract final class PhaseDetector {
  /// Maximum combined non-pawn, non-king material points treated as Endgame.
  static const int kEndgameMaterialThreshold = 13;

  /// Default maximum ply index classified as Opening when not in book.
  static const int kOpeningMaxPly = 24;

  /// Computes combined non-pawn, non-king material across both colours from [fen]
  /// using standard point values (N=3, B=3, R=5, Q=9).
  static int combinedNonPawnNonKingMaterial(String fen) {
    final trimmed = fen.trim();
    if (trimmed.isEmpty) return 0;
    final spaceIdx = trimmed.indexOf(' ');
    final boardPlacement =
        spaceIdx == -1 ? trimmed : trimmed.substring(0, spaceIdx);

    var total = 0;
    for (var i = 0; i < boardPlacement.length; i++) {
      switch (boardPlacement.codeUnitAt(i)) {
        case 0x4E: // 'N'
        case 0x6E: // 'n'
        case 0x42: // 'B'
        case 0x62: // 'b'
          total += 3;
          break;
        case 0x52: // 'R'
        case 0x72: // 'r'
          total += 5;
          break;
        case 0x51: // 'Q'
        case 0x71: // 'q'
          total += 9;
          break;
      }
    }
    return total;
  }

  /// Classifies a position/ply into [GamePhase].
  static GamePhase detect({
    required String fen,
    required int ply,
    bool isBook = false,
  }) {
    if (combinedNonPawnNonKingMaterial(fen) <= kEndgameMaterialThreshold) {
      return GamePhase.endgame;
    }
    if (ply <= kOpeningMaxPly || isBook) {
      return GamePhase.opening;
    }
    return GamePhase.middlegame;
  }
}
