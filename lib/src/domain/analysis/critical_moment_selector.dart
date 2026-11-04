import '../chess/chess_models.dart';

/// Part 11.8, 19-7 & 30.1 (T-MOM-01..03):
/// Selects 5-8 critical moments (or 3-5 for games under 20 moves / 40 plies)
/// with minimum spacing of 3 plies, focusing on the user's moves (or both sides if toggled)
/// and including at least one positive moment when any exists.
class CriticalMomentSelector {
  static List<CriticalMomentEntity> selectMoments({
    required String gameId,
    required List<MoveAnalysisEntity> moves,
    required SideColor userColor,
    bool bothSides = false,
  }) {
    if (moves.isEmpty) return const [];

    final totalPlies = moves.length;
    final isShortGame = totalPlies < 40; // Under 20 full moves
    final minTarget = isShortGame ? 3 : 5;
    final maxTarget = isShortGame ? 5 : 8;

    // Candidate scoring per Part 11.8:
    // S = w1*ΔW + w2*swing_in_state + w3*is_brilliant_or_great + w4*volatility
    final scored = <_ScoredPly>[];

    for (var i = 0; i < moves.length; i++) {
      final m = moves[i];
      if (m.label == MoveClassification.book) continue;

      final isUserMove = m.moverColor == userColor;

      // Part 19-7: Opponent errors appear only as "missed punishment" on the user's reply
      // (user's reply recovers < 70% of opponent's drop), unless bothSides is enabled.
      var missedPunishmentBonus = 0.0;
      var reason = m.label.label;
      if (isUserMove && i > 0) {
        final prevOpponentMove = moves[i - 1];
        if (prevOpponentMove.deltaW >= 15.0 && m.deltaW >= 0.3 * prevOpponentMove.deltaW) {
          missedPunishmentBonus = 18.0;
          reason = 'Missed punishment after opponent mistake';
        }
      }

      if (!bothSides && !isUserMove) continue;

      final stateSwing = _computeStateSwing(m.winBefore, m.winAfter);
      final specialBonus = (m.label == MoveClassification.brilliant ||
              m.label == MoveClassification.great)
          ? 28.0
          : 0.0;

      final score = 1.2 * m.deltaW +
          15.0 * stateSwing +
          specialBonus +
          1.5 * m.volatility +
          missedPunishmentBonus;

      scored.add(
        _ScoredPly(
          analysis: m,
          score: score,
          reason: reason,
          isPositive: m.label == MoveClassification.brilliant ||
              m.label == MoveClassification.great ||
              (m.label == MoveClassification.best && m.volatility >= 3.0),
        ),
      );
    }

    if (scored.isEmpty) return const [];

    // Sort highest score first
    scored.sort((a, b) => b.score.compareTo(a.score));

    final chosen = <_ScoredPly>[];

    // Ensure at least one positive moment if any exists (D-4 AC1, T-MOM-03)
    final bestPositive = scored.where((s) => s.isPositive).firstOrNull;
    if (bestPositive != null) {
      chosen.add(bestPositive);
    }

    // Greedily add highest-scoring plies respecting minimum spacing of 3 plies
    for (final candidate in scored) {
      if (chosen.length >= maxTarget) break;
      if (chosen.any((c) => c.analysis.ply == candidate.analysis.ply)) continue;
      final tooClose =
          chosen.any((c) => (c.analysis.ply - candidate.analysis.ply).abs() < 3);
      if (!tooClose) {
        chosen.add(candidate);
      }
    }

    // If spacing constraint prevented reaching minTarget on a short game, relax spacing to 2
    if (chosen.length < minTarget) {
      for (final candidate in scored) {
        if (chosen.length >= minTarget) break;
        if (chosen.any((c) => c.analysis.ply == candidate.analysis.ply)) {
          continue;
        }
        chosen.add(candidate);
      }
    }

    // Order chronologically in the UI (Part 11.8)
    chosen.sort((a, b) => a.analysis.ply.compareTo(b.analysis.ply));

    return [
      for (var idx = 0; idx < chosen.length; idx++)
        CriticalMomentEntity(
          gameId: gameId,
          ply: chosen[idx].analysis.ply,
          rank: idx + 1,
          reason: chosen[idx].reason,
        ),
    ];
  }

  static double _computeStateSwing(double winBefore, double winAfter) {
    int bucket(double w) {
      if (w >= 65.0) return 1; // Winning
      if (w <= 35.0) return -1; // Losing
      return 0; // Equal
    }

    return (bucket(winBefore) - bucket(winAfter)).abs().toDouble();
  }
}

class _ScoredPly {
  final MoveAnalysisEntity analysis;
  final double score;
  final String reason;
  final bool isPositive;

  const _ScoredPly({
    required this.analysis,
    required this.score,
    required this.reason,
    required this.isPositive,
  });
}
