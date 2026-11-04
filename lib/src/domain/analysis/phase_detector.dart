import '../chess/chess_models.dart';
import '../chess/see_evaluator.dart';

/// Part 19-3: Phase Precedence Rule:
/// 1. Endgame if combined non-pawn, non-king material <= 13 points;
/// 2. Else Opening if ply <= 24 (or still in book);
/// 3. Else Middlegame. (The queens-present rule from v0.1 is dropped).
class PhaseDetector {
  static GamePhase detectPhase({
    required String fen,
    required int ply,
    required bool isBook,
    int endgameMaterialLimit = 13,
    int openingMaxPly = 24,
  }) {
    final material = SeeEvaluator.combinedNonPawnMaterial(fen);
    if (material <= endgameMaterialLimit) {
      return GamePhase.endgame;
    }
    if (ply <= openingMaxPly || isBook) {
      return GamePhase.opening;
    }
    return GamePhase.middlegame;
  }
}
