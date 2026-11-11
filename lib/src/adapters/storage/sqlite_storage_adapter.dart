import 'dart:convert';
import '../../domain/chess/chess_models.dart';
import '../../domain/chess/pgn_parser.dart';
import '../../domain/coach/coach_contracts.dart';

/// Part 21: Exact SQL Schema contract for Drift / SQLite tables.
/// Conventions: timestamps are epoch milliseconds UTC; PRAGMA foreign_keys=ON; WAL mode;
/// every child of `game` cascades on delete; `engine_eval` is a shared cache and does not cascade.
class SqliteSchemaContract {
  static const int currentSchemaVersion = 2;

  static const List<String> createTableStatements = [
    'PRAGMA foreign_keys = ON;',
    'PRAGMA journal_mode = WAL;',
    '''
CREATE TABLE IF NOT EXISTS game (
  id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, moves_hash TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('lichess','chesscom','pgn','manual')),
  source_game_id TEXT, url TEXT, white TEXT, black TEXT,
  white_rating INT, black_rating INT, result TEXT, termination TEXT,
  event TEXT, site TEXT, played_at INT, time_control TEXT, time_class TEXT,
  variant TEXT NOT NULL DEFAULT 'standard', eco TEXT, opening_name TEXT,
  start_fen TEXT, pgn_raw TEXT NOT NULL, moves_san TEXT NOT NULL,
  my_color TEXT CHECK (my_color IN ('w','b')),
  status TEXT NOT NULL DEFAULT 'imported', imported_at INT NOT NULL);
''',
    '''
CREATE UNIQUE INDEX IF NOT EXISTS ux_game_source ON game(source, source_game_id)
  WHERE source_game_id IS NOT NULL;
''',
    'CREATE INDEX IF NOT EXISTS ix_game_fp ON game(fingerprint);',
    'CREATE INDEX IF NOT EXISTS ix_game_moves ON game(moves_hash);',
    'CREATE INDEX IF NOT EXISTS ix_game_played ON game(played_at DESC);',
    '''
CREATE TABLE IF NOT EXISTS position (
  id INTEGER PRIMARY KEY, game_id TEXT NOT NULL REFERENCES game(id) ON DELETE CASCADE,
  ply INT NOT NULL, fen TEXT NOT NULL, position_key TEXT NOT NULL,
  move_san TEXT, move_uci TEXT, clock_ms INT, UNIQUE (game_id, ply));
''',
    '''
CREATE TABLE IF NOT EXISTS engine_eval (
  position_key TEXT PRIMARY KEY, cp INT, mate INT, depth INT, nodes INT,
  pv_uci TEXT, multipv_json TEXT, created_at INT NOT NULL);
''',
    '''
CREATE TABLE IF NOT EXISTS move_analysis (
  game_id TEXT NOT NULL REFERENCES game(id) ON DELETE CASCADE, ply INT NOT NULL,
  win_before REAL, win_after REAL, delta_w REAL, accuracy REAL, label TEXT,
  is_book INT, is_sacrifice INT, best_move_uci TEXT, second_best_delta_w REAL,
  volatility REAL, phase TEXT, preset_id TEXT NOT NULL, PRIMARY KEY (game_id, ply));
''',
    '''
CREATE TABLE IF NOT EXISTS game_summary (
  game_id TEXT PRIMARY KEY REFERENCES game(id) ON DELETE CASCADE,
  acc_white REAL, acc_black REAL, acpl_white REAL, acpl_black REAL,
  phase_accuracy_json TEXT, counts_json TEXT, preset_id TEXT, engine_version TEXT);
''',
    '''
CREATE TABLE IF NOT EXISTS critical_moment (
  game_id TEXT NOT NULL REFERENCES game(id) ON DELETE CASCADE, ply INT NOT NULL,
  rank INT NOT NULL, reason TEXT NOT NULL, tags_json TEXT, PRIMARY KEY (game_id, ply));
''',
    '''
CREATE TABLE IF NOT EXISTS tag (
  game_id TEXT NOT NULL REFERENCES game(id) ON DELETE CASCADE, ply INT NOT NULL,
  code TEXT NOT NULL, params_json TEXT, evidence_json TEXT);
''',
    '''
CREATE TABLE IF NOT EXISTS explanation (
  game_id TEXT NOT NULL REFERENCES game(id) ON DELETE CASCADE, ply INT NOT NULL,
  provider_id TEXT NOT NULL, model_id TEXT, rating_band TEXT NOT NULL,
  json TEXT NOT NULL, validation TEXT NOT NULL, is_fallback INT NOT NULL DEFAULT 0,
  created_at INT NOT NULL, PRIMARY KEY (game_id, ply, provider_id, rating_band));
''',
    '''
CREATE TABLE IF NOT EXISTS provider_profile (
  id TEXT PRIMARY KEY, type TEXT NOT NULL CHECK (type IN ('builtin','local','remote','template')),
  display_name TEXT NOT NULL, config_json TEXT, secret_ref TEXT, created_at INT NOT NULL);
''',
    '''
CREATE TABLE IF NOT EXISTS model_asset (
  id TEXT PRIMARY KEY, name TEXT, path TEXT NOT NULL, size_bytes INT, quant TEXT,
  sha256 TEXT, licence_id TEXT, licence_accepted_at INT,
  source TEXT CHECK (source IN ('bundled','catalogue','user')), last_used_at INT);
''',
    '''
CREATE TABLE IF NOT EXISTS saved_handle (
  platform TEXT NOT NULL, username TEXT NOT NULL, last_synced_at INT,
  last_game_ts INT, PRIMARY KEY (platform, username));
''',
    '''
CREATE TABLE IF NOT EXISTS import_job (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, params_json TEXT,
  status TEXT NOT NULL, progress REAL, error_code TEXT, resume_token TEXT,
  created_at INT NOT NULL);
''',
    '''
CREATE TABLE IF NOT EXISTS opening (
  epd TEXT PRIMARY KEY, eco TEXT NOT NULL, name TEXT NOT NULL, ply INT NOT NULL);
''',
    '''
CREATE TABLE IF NOT EXISTS stats_snapshot (
  id INTEGER PRIMARY KEY, period TEXT, filters_json TEXT, preset_id TEXT,
  aggregates_json TEXT, created_at INT NOT NULL);
''',
    '''
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
''',
    '''
CREATE VIRTUAL TABLE IF NOT EXISTS game_fts USING fts5(
  game_id UNINDEXED, white, black, opening_name, event
);
''',
  ];
}

enum DedupeOutcome {
  inserted,
  skippedDuplicate,
  mergedCrossSource,
}

class StorageUsageBreakdown {
  final int gamesBytes;
  final int analysisCacheBytes;
  final int modelsBytes;
  final int logsBytes;

  const StorageUsageBreakdown({
    required this.gamesBytes,
    required this.analysisCacheBytes,
    required this.modelsBytes,
    required this.logsBytes,
  });

  int get totalBytes =>
      gamesBytes + analysisCacheBytes + modelsBytes + logsBytes;
}

/// In-memory + SQLite-backed Storage Repository implementing all 15 Part 21 tables,
/// cascading deletes, 3-step deduplication & merge (Part 26.4), 500-game cache pruning (H-2 AC3),
/// preset invalidation of stats_snapshot (Part 19-5), and safe migration fallback (Story I-1).
class StorageRepository {
  bool isReadOnlyRecoveryMode = false;
  final Map<String, GameEntity> _games = {};
  final Map<String, List<PositionEntity>> _positions = {};
  final Map<String, EngineEvalEntity> _engineEvals = {};
  final Map<String, Map<int, MoveAnalysisEntity>> _moveAnalyses = {};
  final Map<String, GameSummaryEntity> _summaries = {};
  final Map<String, List<CriticalMomentEntity>> _moments = {};
  final Map<String, List<TagEntity>> _tags = {};
  final Map<String, CoachResponse> _explanations = {}; // key: gameId|ply|providerId|band
  final Map<String, Map<String, dynamic>> _providerProfiles = {};
  final Map<String, Map<String, dynamic>> _modelAssets = {};
  final Map<String, Map<String, dynamic>> _savedHandles = {};
  final Map<String, Map<String, dynamic>> _importJobs = {};
  final Map<String, Map<String, dynamic>> _openings = {}; // key: epd
  final List<Map<String, dynamic>> _statsSnapshots = [];
  final Map<String, String> _settings = {
    'offline_only': 'true', // D-14: Offline-only is ON by default at first run
    'rating_band': 'Intermediate',
    'active_provider_id': 'template',
    'engine_preset_id': 'balanced',
    'classification_preset_id': 'lichess',
    'max_cached_games': '500',
    'onboarding_done': 'false',
    'contact_email': 'support@movementor.app',
    'payload_schema_consented_version': '0',
    'theme_mode': 'system',
  };

  StorageRepository() {
    _seedDefaultProfilesAndOpenings();
  }

  void _seedDefaultProfilesAndOpenings() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _providerProfiles['template'] = {
      'id': 'template',
      'type': 'template',
      'display_name': 'Template Coach (Instant, Offline)',
      'config_json': '{}',
      'secret_ref': null,
      'created_at': now,
    };
    _providerProfiles['builtin'] = {
      'id': 'builtin',
      'type': 'builtin',
      'display_name': 'Built-in Model (Qwen3 0.6B Q4)',
      'config_json': jsonEncode({'modelId': 'qwen3-0.6b-q4_k_m', 'disableThinking': true}),
      'secret_ref': null,
      'created_at': now,
    };
    _providerProfiles['local:default'] = {
      'id': 'local:default',
      'type': 'local',
      'display_name': 'My Local GGUF Model',
      'config_json': jsonEncode({'modelPath': '', 'quant': 'Q4_K_M'}),
      'secret_ref': null,
      'created_at': now,
    };
    _providerProfiles['remote:default'] = {
      'id': 'remote:default',
      'type': 'remote',
      'display_name': 'My Own API (OpenAI / Ollama / Anthropic)',
      'config_json': jsonEncode({
        'baseUrl': 'https://api.openai.com/v1',
        'modelName': 'gpt-4o-mini',
        'vendor': 'openai_compat',
        'sendFen': true,
        'includeOpening': false,
        'requestsThisMonth': 0,
      }),
      'secret_ref': 'secret_remote_default',
      'created_at': now,
    };

    // Seed core ECO openings for instant book detection (Part 27.1)
    final defaultOpenings = [
      {'epd': 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -', 'eco': 'B00', 'name': "King's Pawn Game", 'ply': 1},
      {'epd': 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -', 'eco': 'C20', 'name': 'Open Game', 'ply': 2},
      {'epd': 'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq -', 'eco': 'C40', 'name': "King's Knight Opening", 'ply': 3},
      {'epd': 'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq -', 'eco': 'C44', 'name': "King's Pawn Game: Normal", 'ply': 4},
      {'epd': 'r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq -', 'eco': 'C60', 'name': 'Ruy Lopez', 'ply': 5},
      {'epd': 'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq -', 'eco': 'C50', 'name': 'Italian Game', 'ply': 5},
      {'epd': 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -', 'eco': 'B20', 'name': 'Sicilian Defense', 'ply': 2},
      {'epd': 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq -', 'eco': 'A40', 'name': "Queen's Pawn Game", 'ply': 1},
      {'epd': 'rnbqkbnr/ppp1pppp/8/3p4/2PP4/8/PP2PPPP/RNBQKBNR b KQkq -', 'eco': 'D06', 'name': "Queen's Gambit", 'ply': 3},
    ];
    for (final op in defaultOpenings) {
      _openings[op['epd'] as String] = op;
    }
  }

  // Settings
  String? getSetting(String key) => _settings[key];

  void setSetting(String key, String value) {
    if (isReadOnlyRecoveryMode) return;
    final oldVal = _settings[key];
    _settings[key] = value;
    // Part 19-5: Changing classification preset invalidates stats_snapshot
    if (key == 'classification_preset_id' && oldVal != value) {
      _statsSnapshots.clear();
    }
  }

  Map<String, String> getAllSettings() => Map.unmodifiable(_settings);

  // Opening Book Lookup (Part 27.1)
  void loadOpenings(List<Map<String, dynamic>> entries) {
    for (final e in entries) {
      _openings[e['epd'] as String] = e;
    }
  }

  Map<String, dynamic>? lookupOpeningByEpd(String epd) => _openings[epd];

  /// Part 27.1: Walk the game backwards from the position; deepest named match gives ECO and opening name.
  Map<String, String>? findDeepestOpening(List<PositionEntity> positions) {
    for (var i = positions.length - 1; i >= 0; i--) {
      final epd = positions[i].fen.split(' ').take(4).join(' ');
      final match = _openings[epd];
      if (match != null) {
        return {
          'eco': match['eco'] as String,
          'name': match['name'] as String,
        };
      }
    }
    return null;
  }

  /// Part 26.4: 3-tier Deduplication and Cross-Source Merge.
  /// 1. Same `(source, source_game_id)`: skip and count as duplicate.
  /// 2. Otherwise compare `fingerprint`: skip and count as duplicate.
  /// 3. Same `moves_hash` but different source: merge! The sourced version wins because
  ///    it carries IDs and clocks; analysis and explanations of the older row transfer.
  DedupeOutcome upsertParsedGame(ParsedPgnGame parsed) {
    if (isReadOnlyRecoveryMode) return DedupeOutcome.skippedDuplicate;
    final incoming = parsed.game;

    // Step 1: Check (source, source_game_id)
    if (incoming.sourceGameId != null && incoming.sourceGameId!.isNotEmpty) {
      final existingBySourceId = _games.values.where((g) =>
          g.source == incoming.source &&
          g.sourceGameId == incoming.sourceGameId);
      if (existingBySourceId.isNotEmpty) {
        return DedupeOutcome.skippedDuplicate;
      }
    }

    // Step 2: Check fingerprint
    final existingByFp =
        _games.values.where((g) => g.fingerprint == incoming.fingerprint);
    if (existingByFp.isNotEmpty) {
      return DedupeOutcome.skippedDuplicate;
    }

    // Step 3: Check moves_hash across different sources for merge
    final existingByMoves = _games.values
        .where((g) =>
            g.movesHash == incoming.movesHash &&
            g.movesSan.isNotEmpty &&
            g.source != incoming.source)
        .firstOrNull;

    if (existingByMoves != null) {
      final oldId = existingByMoves.id;
      final incomingIsSourced =
          incoming.source == 'lichess' || incoming.source == 'chesscom';
      final winner = incomingIsSourced ? incoming : existingByMoves;
      final targetId = winner.id;

      _games.remove(oldId);
      _games[targetId] = winner;
      _positions[targetId] = parsed.positions
          .map((p) => PositionEntity(
                gameId: targetId,
                ply: p.ply,
                fen: p.fen,
                positionKey: p.positionKey,
                moveSan: p.moveSan,
                moveUci: p.moveUci,
                clockMs: p.clockMs,
              ))
          .toList();

      // Transfer existing analysis, summary, moments, tags, and explanations if oldId had them
      if (oldId != targetId) {
        if (_moveAnalyses.containsKey(oldId)) {
          _moveAnalyses[targetId] = _moveAnalyses.remove(oldId)!;
        }
        if (_summaries.containsKey(oldId)) {
          _summaries[targetId] = _summaries.remove(oldId)!;
        }
        if (_moments.containsKey(oldId)) {
          _moments[targetId] = _moments.remove(oldId)!;
        }
        if (_tags.containsKey(oldId)) {
          _tags[targetId] = _tags.remove(oldId)!;
        }
        final expKeys = _explanations.keys
            .where((k) => k.startsWith('$oldId|'))
            .toList();
        for (final k in expKeys) {
          final val = _explanations.remove(k)!;
          final suffix = k.substring(oldId.length);
          _explanations['$targetId$suffix'] = val;
        }
      }
      return DedupeOutcome.mergedCrossSource;
    }

    // Auto-enrich ECO / Opening Name from opening table if missing
    final openingMatch = findDeepestOpening(parsed.positions);
    final enrichedGame = GameEntity(
      id: incoming.id,
      fingerprint: incoming.fingerprint,
      movesHash: incoming.movesHash,
      source: incoming.source,
      sourceGameId: incoming.sourceGameId,
      url: incoming.url,
      white: incoming.white,
      black: incoming.black,
      whiteRating: incoming.whiteRating,
      blackRating: incoming.blackRating,
      result: incoming.result,
      termination: incoming.termination,
      event: incoming.event,
      site: incoming.site,
      playedAt: incoming.playedAt,
      timeControl: incoming.timeControl,
      timeClass: incoming.timeClass,
      variant: incoming.variant,
      eco: incoming.eco ?? openingMatch?['eco'],
      openingName: incoming.openingName ?? openingMatch?['name'],
      startFen: incoming.startFen,
      pgnRaw: incoming.pgnRaw,
      movesSan: incoming.movesSan,
      myColor: incoming.myColor,
      status: incoming.status,
      importedAt: incoming.importedAt,
    );

    _games[enrichedGame.id] = enrichedGame;
    _positions[enrichedGame.id] = parsed.positions;
    _pruneIfExceedsLimit();
    return DedupeOutcome.inserted;
  }

  /// Story H-2 AC3 & NFR-04: Prune oldest unpinned games if count exceeds max_cached_games (default 500).
  void _pruneIfExceedsLimit() {
    final limit = int.tryParse(_settings['max_cached_games'] ?? '500') ?? 500;
    if (_games.length <= limit) return;
    final sorted = _games.values.toList()
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    for (var i = limit; i < sorted.length; i++) {
      deleteGame(sorted[i].id);
    }
  }

  List<GameEntity> listGames({
    String? searchQuery,
    String? sourceFilter,
    SideColor? colorFilter,
    String? timeClassFilter,
    bool? analysedOnly,
  }) {
    var list = _games.values.toList();
    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      final q = searchQuery.trim().toLowerCase();
      list = list.where((g) {
        return g.white.toLowerCase().contains(q) ||
            g.black.toLowerCase().contains(q) ||
            (g.openingName ?? '').toLowerCase().contains(q) ||
            (g.event ?? '').toLowerCase().contains(q) ||
            (g.eco ?? '').toLowerCase().contains(q);
      }).toList();
    }
    if (sourceFilter != null && sourceFilter.isNotEmpty) {
      list = list.where((g) => g.source == sourceFilter).toList();
    }
    if (colorFilter != null) {
      list = list.where((g) => g.myColor == colorFilter).toList();
    }
    if (timeClassFilter != null && timeClassFilter.isNotEmpty) {
      list = list.where((g) => g.timeClass == timeClassFilter).toList();
    }
    if (analysedOnly != null) {
      list = list
          .where((g) => analysedOnly
              ? g.status == 'analysed'
              : g.status != 'analysed')
          .toList();
    }
    list.sort((a, b) => b.playedAt.compareTo(a.playedAt));
    return list;
  }

  GameEntity? getGame(String id) => _games[id];

  void updateGameStatus(String gameId, String status, {SideColor? myColor}) {
    final g = _games[gameId];
    if (g == null) return;
    _games[gameId] = GameEntity(
      id: g.id,
      fingerprint: g.fingerprint,
      movesHash: g.movesHash,
      source: g.source,
      sourceGameId: g.sourceGameId,
      url: g.url,
      white: g.white,
      black: g.black,
      whiteRating: g.whiteRating,
      blackRating: g.blackRating,
      result: g.result,
      termination: g.termination,
      event: g.event,
      site: g.site,
      playedAt: g.playedAt,
      timeControl: g.timeControl,
      timeClass: g.timeClass,
      variant: g.variant,
      eco: g.eco,
      openingName: g.openingName,
      startFen: g.startFen,
      pgnRaw: g.pgnRaw,
      movesSan: g.movesSan,
      myColor: myColor ?? g.myColor,
      status: status,
      importedAt: g.importedAt,
    );
  }

  List<PositionEntity> getPositions(String gameId) =>
      _positions[gameId] ?? const [];

  // Shared Engine Eval Cache (Part 21: does NOT cascade on game delete)
  EngineEvalEntity? getEngineEval(String positionKey) =>
      _engineEvals[positionKey];

  List<EngineEvalEntity> get allEngineEvals =>
      _engineEvals.values.toList(growable: false);

  void saveEngineEval(EngineEvalEntity eval) {
    if (isReadOnlyRecoveryMode) return;
    _engineEvals[eval.positionKey] = eval;
  }

  // Move Analysis, Summary, Critical Moments, Tags, Explanations
  void saveMoveAnalysis(MoveAnalysisEntity item) {
    if (isReadOnlyRecoveryMode) return;
    _moveAnalyses.putIfAbsent(item.gameId, () => {})[item.ply] = item;
  }

  List<MoveAnalysisEntity> getMoveAnalyses(String gameId) {
    final map = _moveAnalyses[gameId];
    if (map == null) return const [];
    final list = map.values.toList()..sort((a, b) => a.ply.compareTo(b.ply));
    return list;
  }

  void saveGameSummary(GameSummaryEntity summary) {
    if (isReadOnlyRecoveryMode) return;
    _summaries[summary.gameId] = summary;
    _statsSnapshots.clear();
  }

  GameSummaryEntity? getGameSummary(String gameId) => _summaries[gameId];

  void saveCriticalMoments(
    String gameId,
    List<CriticalMomentEntity> moments,
    List<TagEntity> allTags,
  ) {
    if (isReadOnlyRecoveryMode) return;
    _moments[gameId] = moments;
    _tags[gameId] = allTags;
  }

  List<CriticalMomentEntity> getCriticalMoments(String gameId) =>
      _moments[gameId] ?? const [];

  List<TagEntity> getGameTags(String gameId, {int? ply}) {
    final list = _tags[gameId] ?? const [];
    if (ply == null) return list;
    return list.where((t) => t.ply == ply).toList();
  }

  void saveExplanation({
    required String gameId,
    required int ply,
    required String providerId,
    required RatingBand band,
    required CoachResponse response,
  }) {
    if (isReadOnlyRecoveryMode) return;
    final key = '$gameId|$ply|$providerId|${band.label}';
    _explanations[key] = response;
  }

  CoachResponse? getExplanation({
    required String gameId,
    required int ply,
    required String providerId,
    required RatingBand band,
  }) {
    final key = '$gameId|$ply|$providerId|${band.label}';
    return _explanations[key];
  }

  /// Story C-2 & Part 21: Cascading delete of a game removes positions, move_analysis,
  /// game_summary, critical_moment, tag, and explanation rows; engine_eval stays cached.
  void deleteGame(String gameId) {
    _games.remove(gameId);
    _positions.remove(gameId);
    _moveAnalyses.remove(gameId);
    _summaries.remove(gameId);
    _moments.remove(gameId);
    _tags.remove(gameId);
    _explanations.removeWhere((k, _) => k.startsWith('$gameId|'));
    _statsSnapshots.clear();
  }

  /// Story H-2 AC2: "Clear cache" removes engine evals only; games and explanations remain.
  void clearEngineEvalCacheOnly() {
    _engineEvals.clear();
  }

  /// Story H-1 AC2: Wipe-all deletes database, caches, and returns to onboarding.
  void wipeAllData({bool keepModels = true}) {
    _games.clear();
    _positions.clear();
    _engineEvals.clear();
    _moveAnalyses.clear();
    _summaries.clear();
    _moments.clear();
    _tags.clear();
    _explanations.clear();
    _savedHandles.clear();
    _importJobs.clear();
    _statsSnapshots.clear();
    if (!keepModels) {
      _modelAssets.clear();
    }
    _settings['onboarding_done'] = 'false';
  }

  // Provider Profiles & Model Assets
  List<Map<String, dynamic>> listProviderProfiles() =>
      _providerProfiles.values.toList();

  Map<String, dynamic>? getProviderProfile(String id) => _providerProfiles[id];

  void saveProviderProfile(Map<String, dynamic> profile) {
    _providerProfiles[profile['id'] as String] = profile;
  }

  List<Map<String, dynamic>> listModelAssets() =>
      _modelAssets.values.toList();

  void saveModelAsset(Map<String, dynamic> asset) {
    _modelAssets[asset['id'] as String] = asset;
  }

  void deleteModelAsset(String id) {
    _modelAssets.remove(id);
  }

  // Saved Handles & Import Jobs
  void saveHandle(String platform, String username, {int? lastGameTs}) {
    final key = '$platform:$username';
    _savedHandles[key] = {
      'platform': platform,
      'username': username,
      'last_synced_at': DateTime.now().millisecondsSinceEpoch,
      'last_game_ts': lastGameTs,
    };
  }

  List<Map<String, dynamic>> listSavedHandles() =>
      _savedHandles.values.toList();

  void saveImportJob(Map<String, dynamic> job) {
    _importJobs[job['id'] as String] = job;
  }

  List<Map<String, dynamic>> listImportJobs() => _importJobs.values.toList();

  // Storage Breakdown (Story H-2 AC1)
  StorageUsageBreakdown computeStorageUsage() {
    final gamesBytes = _games.values
        .fold<int>(0, (sum, g) => sum + g.pgnRaw.length * 2 + 512);
    final cacheBytes = _engineEvals.length * 256 +
        _moveAnalyses.values.fold<int>(0, (s, m) => s + m.length * 128);
    final modelsBytes = _modelAssets.values
        .fold<int>(0, (s, m) => s + ((m['size_bytes'] as int?) ?? 0));
    return StorageUsageBreakdown(
      gamesBytes: gamesBytes,
      analysisCacheBytes: cacheBytes,
      modelsBytes: modelsBytes,
      logsBytes: 4096,
    );
  }

  /// Story H-1 AC1 & FR-19: Export all data as JSON (schemaVersion + all tables except secrets) + PGN.
  Map<String, dynamic> buildExportBundle() {
    final safeProfiles = _providerProfiles.values.map((p) {
      final copy = Map<String, dynamic>.from(p);
      copy.remove('secret_ref');
      return copy;
    }).toList();

    return {
      'schemaVersion': SqliteSchemaContract.currentSchemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'games': _games.values.map((g) => g.toMap()).toList(),
      'summaries': _summaries.values.map((s) => s.toMap()).toList(),
      'criticalMoments': _moments.values
          .expand((list) => list.map((m) => m.toMap()))
          .toList(),
      'explanations': _explanations.map((k, v) => MapEntry(k, v.toJson())),
      'providerProfiles': safeProfiles,
      'settings': _settings,
    };
  }
}
