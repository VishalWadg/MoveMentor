/// Execution budget for engine analysis.
///
/// SPEC RULES:
/// - Engine determinism: tests use fixed nodes ONLY (never mix depth, nodes and movetime).
/// - Test mode: fixed nodes only, Threads 1, fixed Hash.
class EngineBudget {
  /// Deterministic fixed node count to search.
  final int nodes;

  /// UCI Threads setting (default 1 for strict determinism).
  final int threads;

  /// UCI Hash table size in Megabytes (default 16 MB).
  final int hashMb;

  const EngineBudget({
    required this.nodes,
    this.threads = 1,
    this.hashMb = 16,
  });

  /// Settings hash for cache key generation.
  String get settingsHash => 'nodes_${nodes}_threads_${threads}_hash_$hashMb';
}

/// A single principal variation line returned by the engine.
class EnginePvLine {
  /// 1-based multiPV ranking (1 = top move, 2 = second-best, etc.)
  final int multiPvRank;

  /// Engine evaluation in centipawns (from side-to-move's perspective).
  final int? cp;

  /// Engine evaluation in mate distance (positive if mover mates, negative if mover is mated).
  final int? mate;

  /// Win percentage [0.0, 100.0] derived from cp or mate.
  final double winPercent;

  /// Played move in UCI notation (e.g. "e2e4").
  final String moveUci;

  /// Full PV moves in UCI notation.
  final List<String> pv;

  const EnginePvLine({
    required this.multiPvRank,
    this.cp,
    this.mate,
    required this.winPercent,
    required this.moveUci,
    required this.pv,
  });
}

/// Analysis result for a single position.
class EngineAnalysisResult {
  /// Normalized FEN analyzed.
  final String fen;

  /// Engine identifier/version string (e.g. "Stockfish 17").
  final String engineVersion;

  /// Budget used for this analysis.
  final EngineBudget budget;

  /// Top lines returned (ordered from best to worst).
  final List<EnginePvLine> lines;

  /// Evaluated node count.
  final int nodes;

  /// Best move in UCI notation (from multiPV line 1).
  /// Null if no moves are available (terminal position) or engine returned empty PV.
  String? get bestMoveUci => lines.isEmpty ? null : lines.first.moveUci;

  /// Top line evaluation from side-to-move's perspective.
  EnginePvLine? get topLine => lines.isEmpty ? null : lines.first;

  const EngineAnalysisResult({
    required this.fen,
    required this.engineVersion,
    required this.budget,
    required this.lines,
    required this.nodes,
  });

  /// Canonicalizes FEN spacing and trims leading/trailing whitespace.
  static String normalizeFen(String fen) =>
      fen.trim().split(RegExp(r'\s+')).join(' ');

  /// Computes deterministic cache key:
  /// normalised FEN + engine version + settings hash + MultiPV count.
  static String computeCacheKey({
    required String normalizedFen,
    required String engineVersion,
    required EngineBudget budget,
    required int multiPv,
  }) {
    final norm = normalizeFen(normalizedFen);
    return '$norm#$engineVersion#${budget.settingsHash}#multipv_$multiPv';
  }
}

/// Port for chess engine services.
///
/// SPEC RULES:
/// - Perspective: engine scores are relative to the side to move.
/// - analyse(fen, multiPv, budget) -> scores relative to side to move, plus pv.
/// - Handshake: checkHealth() verifies real engine responsiveness (e.g. uciok).
/// - Determinism: newGame() sends "ucinewgame" then "isready" before each game.
abstract class EngineServicePort {
  /// Unique engine identifier/version.
  String get engineVersion;

  /// Performs health check / handshake (e.g. sends "uci" -> awaits "uciok").
  /// Returns true if genuine UCI engine responded correctly.
  Future<bool> checkHealth();

  /// Prepares engine for a new independent game (sends "ucinewgame" then "isready").
  Future<void> newGame();

  /// Analyzes a position at fixed budget and multiPV lines.
  /// All evaluations in returned lines are relative to the side to move.
  Future<EngineAnalysisResult> analyse(
    String fen, {
    int multiPv = 1,
    required EngineBudget budget,
  });

  /// Releases resources / kills engine process.
  Future<void> dispose();
}
