import 'dart:convert';

enum SideColor {
  w,
  b;

  String get label => this == SideColor.w ? 'white' : 'black';
  String get display => this == SideColor.w ? 'White' : 'Black';
  SideColor get opposite => this == SideColor.w ? SideColor.b : SideColor.w;

  static SideColor fromCode(String? code) =>
      code == 'b' ? SideColor.b : SideColor.w;
}

enum GamePhase {
  opening('Opening'),
  middlegame('Middlegame'),
  endgame('Endgame');

  final String label;
  const GamePhase(this.label);

  static GamePhase fromLabel(String? s) {
    switch (s) {
      case 'Opening':
        return GamePhase.opening;
      case 'Endgame':
        return GamePhase.endgame;
      default:
        return GamePhase.middlegame;
    }
  }
}

/// Part 11.5: Strict precedence order (1..9).
enum MoveClassification {
  book('Book', 1, isPositive: false),
  brilliant('Brilliant', 2, isPositive: true),
  great('Great', 3, isPositive: true),
  best('Best', 4, isPositive: true),
  excellent('Excellent', 5, isPositive: false),
  good('Good', 6, isPositive: false),
  inaccuracy('Inaccuracy', 7, isPositive: false),
  mistake('Mistake', 8, isPositive: false),
  blunder('Blunder', 9, isPositive: false);

  final String label;
  final int precedence;
  final bool isPositive;

  const MoveClassification(
    this.label,
    this.precedence, {
    required this.isPositive,
  });

  bool get isNegative =>
      this == MoveClassification.inaccuracy ||
      this == MoveClassification.mistake ||
      this == MoveClassification.blunder;

  static MoveClassification fromLabel(String? label) {
    for (final val in MoveClassification.values) {
      if (val.label.toLowerCase() == (label ?? '').toLowerCase()) {
        return val;
      }
    }
    return MoveClassification.good;
  }
}

/// Part 12.6 & 23.2: Rating bands for adaptive coaching.
enum RatingBand {
  novice('Novice', 0, 999),
  intermediate('Intermediate', 1000, 1599),
  advanced('Advanced', 1600, 2099),
  master('Master', 2100, 3500);

  final String label;
  final int minElo;
  final int maxElo;

  const RatingBand(this.label, this.minElo, this.maxElo);

  static RatingBand fromRating(int rating) {
    if (rating < 1000) return RatingBand.novice;
    if (rating < 1600) return RatingBand.intermediate;
    if (rating < 2100) return RatingBand.advanced;
    return RatingBand.master;
  }

  static RatingBand fromLabel(String? s) {
    for (final b in RatingBand.values) {
      if (b.label.toLowerCase() == (s ?? '').toLowerCase()) return b;
    }
    return RatingBand.intermediate;
  }
}

class GameEntity {
  final String id;
  final String fingerprint;
  final String movesHash;
  final String source; // 'lichess','chesscom','pgn','manual'
  final String? sourceGameId;
  final String? url;
  final String white;
  final String black;
  final int? whiteRating;
  final int? blackRating;
  final String result;
  final String? termination;
  final String? event;
  final String? site;
  final int playedAt;
  final String? timeControl;
  final String? timeClass;
  final String variant;
  final String? eco;
  final String? openingName;
  final String? startFen;
  final String pgnRaw;
  final List<String> movesSan;
  final SideColor myColor;
  final String status; // 'imported','analysing','analysed','partially_valid','not_analysable'
  final int importedAt;

  const GameEntity({
    required this.id,
    required this.fingerprint,
    required this.movesHash,
    required this.source,
    this.sourceGameId,
    this.url,
    required this.white,
    required this.black,
    this.whiteRating,
    this.blackRating,
    required this.result,
    this.termination,
    this.event,
    this.site,
    required this.playedAt,
    this.timeControl,
    this.timeClass,
    this.variant = 'standard',
    this.eco,
    this.openingName,
    this.startFen,
    required this.pgnRaw,
    required this.movesSan,
    this.myColor = SideColor.w,
    this.status = 'imported',
    required this.importedAt,
  });

  bool get isAnalysable =>
      variant.toLowerCase() == 'standard' && status != 'not_analysable';

  String get opponentName => myColor == SideColor.w ? black : white;

  Map<String, dynamic> toMap() => {
        'id': id,
        'fingerprint': fingerprint,
        'moves_hash': movesHash,
        'source': source,
        'source_game_id': sourceGameId,
        'url': url,
        'white': white,
        'black': black,
        'white_rating': whiteRating,
        'black_rating': blackRating,
        'result': result,
        'termination': termination,
        'event': event,
        'site': site,
        'played_at': playedAt,
        'time_control': timeControl,
        'time_class': timeClass,
        'variant': variant,
        'eco': eco,
        'opening_name': openingName,
        'start_fen': startFen,
        'pgn_raw': pgnRaw,
        'moves_san': jsonEncode(movesSan),
        'my_color': myColor.name,
        'status': status,
        'imported_at': importedAt,
      };

  factory GameEntity.fromMap(Map<String, dynamic> map) {
    final rawMoves = map['moves_san'] as String? ?? '[]';
    List<String> parsedMoves;
    try {
      parsedMoves = (jsonDecode(rawMoves) as List<dynamic>).cast<String>();
    } catch (_) {
      parsedMoves = rawMoves
          .split(' ')
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    return GameEntity(
      id: map['id'] as String,
      fingerprint: map['fingerprint'] as String,
      movesHash: map['moves_hash'] as String,
      source: map['source'] as String,
      sourceGameId: map['source_game_id'] as String?,
      url: map['url'] as String?,
      white: (map['white'] as String?) ?? 'White',
      black: (map['black'] as String?) ?? 'Black',
      whiteRating: map['white_rating'] as int?,
      blackRating: map['black_rating'] as int?,
      result: (map['result'] as String?) ?? '*',
      termination: map['termination'] as String?,
      event: map['event'] as String?,
      site: map['site'] as String?,
      playedAt: (map['played_at'] as int?) ?? 0,
      timeControl: map['time_control'] as String?,
      timeClass: map['time_class'] as String?,
      variant: (map['variant'] as String?) ?? 'standard',
      eco: map['eco'] as String?,
      openingName: map['opening_name'] as String?,
      startFen: map['start_fen'] as String?,
      pgnRaw: (map['pgn_raw'] as String?) ?? '',
      movesSan: parsedMoves,
      myColor: SideColor.fromCode(map['my_color'] as String?),
      status: (map['status'] as String?) ?? 'imported',
      importedAt: (map['imported_at'] as int?) ?? 0,
    );
  }
}

class PositionEntity {
  final int? id;
  final String gameId;
  final int ply;
  final String fen;
  final String positionKey;
  final String? moveSan;
  final String? moveUci;
  final int? clockMs;

  const PositionEntity({
    this.id,
    required this.gameId,
    required this.ply,
    required this.fen,
    required this.positionKey,
    this.moveSan,
    this.moveUci,
    this.clockMs,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'game_id': gameId,
        'ply': ply,
        'fen': fen,
        'position_key': positionKey,
        'move_san': moveSan,
        'move_uci': moveUci,
        'clock_ms': clockMs,
      };

  factory PositionEntity.fromMap(Map<String, dynamic> map) => PositionEntity(
        id: map['id'] as int?,
        gameId: map['game_id'] as String,
        ply: map['ply'] as int,
        fen: map['fen'] as String,
        positionKey: map['position_key'] as String,
        moveSan: map['move_san'] as String?,
        moveUci: map['move_uci'] as String?,
        clockMs: map['clock_ms'] as int?,
      );
}

class EngineEvalEntity {
  final String positionKey;
  final int? cp; // From side-to-move perspective
  final int? mate; // Positive if side-to-move mates, negative if mated
  final int depth;
  final int nodes;
  final List<String> pvUci;
  final List<Map<String, dynamic>> multipv;
  final int createdAt;

  const EngineEvalEntity({
    required this.positionKey,
    this.cp,
    this.mate,
    required this.depth,
    required this.nodes,
    required this.pvUci,
    this.multipv = const [],
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'position_key': positionKey,
        'cp': cp,
        'mate': mate,
        'depth': depth,
        'nodes': nodes,
        'pv_uci': pvUci.join(' '),
        'multipv_json': jsonEncode(multipv),
        'created_at': createdAt,
      };

  factory EngineEvalEntity.fromMap(Map<String, dynamic> map) {
    final pvStr = (map['pv_uci'] as String?) ?? '';
    final mpvStr = (map['multipv_json'] as String?) ?? '[]';
    return EngineEvalEntity(
      positionKey: map['position_key'] as String,
      cp: map['cp'] as int?,
      mate: map['mate'] as int?,
      depth: (map['depth'] as int?) ?? 12,
      nodes: (map['nodes'] as int?) ?? 0,
      pvUci: pvStr.isEmpty ? const [] : pvStr.split(' '),
      multipv: (jsonDecode(mpvStr) as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      createdAt: (map['created_at'] as int?) ?? 0,
    );
  }
}

class MoveAnalysisEntity {
  final String gameId;
  final int ply;
  final double winBefore;
  final double winAfter;
  final double deltaW;
  final double accuracy;
  final MoveClassification label;
  final bool isBook;
  final bool isSacrifice;
  final String? bestMoveUci;
  final String? bestMoveSan;
  final double? secondBestDeltaW;
  final double volatility;
  final GamePhase phase;
  final String presetId;

  const MoveAnalysisEntity({
    required this.gameId,
    required this.ply,
    required this.winBefore,
    required this.winAfter,
    required this.deltaW,
    required this.accuracy,
    required this.label,
    required this.isBook,
    required this.isSacrifice,
    this.bestMoveUci,
    this.bestMoveSan,
    this.secondBestDeltaW,
    required this.volatility,
    required this.phase,
    required this.presetId,
  });

  SideColor get moverColor => ply.isOdd ? SideColor.w : SideColor.b;

  Map<String, dynamic> toMap() => {
        'game_id': gameId,
        'ply': ply,
        'win_before': winBefore,
        'win_after': winAfter,
        'delta_w': deltaW,
        'accuracy': accuracy,
        'label': label.label,
        'is_book': isBook ? 1 : 0,
        'is_sacrifice': isSacrifice ? 1 : 0,
        'best_move_uci': bestMoveUci,
        'second_best_delta_w': secondBestDeltaW,
        'volatility': volatility,
        'phase': phase.label,
        'preset_id': presetId,
      };

  factory MoveAnalysisEntity.fromMap(Map<String, dynamic> map) =>
      MoveAnalysisEntity(
        gameId: map['game_id'] as String,
        ply: map['ply'] as int,
        winBefore: (map['win_before'] as num?)?.toDouble() ?? 50.0,
        winAfter: (map['win_after'] as num?)?.toDouble() ?? 50.0,
        deltaW: (map['delta_w'] as num?)?.toDouble() ?? 0.0,
        accuracy: (map['accuracy'] as num?)?.toDouble() ?? 100.0,
        label: MoveClassification.fromLabel(map['label'] as String?),
        isBook: (map['is_book'] as int? ?? 0) == 1,
        isSacrifice: (map['is_sacrifice'] as int? ?? 0) == 1,
        bestMoveUci: map['best_move_uci'] as String?,
        secondBestDeltaW: (map['second_best_delta_w'] as num?)?.toDouble(),
        volatility: (map['volatility'] as num?)?.toDouble() ?? 0.5,
        phase: GamePhase.fromLabel(map['phase'] as String?),
        presetId: (map['preset_id'] as String?) ?? 'lichess',
      );
}

class GameSummaryEntity {
  final String gameId;
  final double accWhite;
  final double accBlack;
  final double acplWhite;
  final double acplBlack;
  final Map<String, Map<String, double>> phaseAccuracy;
  final Map<String, Map<String, int>> counts;
  final String presetId;
  final String engineVersion;

  const GameSummaryEntity({
    required this.gameId,
    required this.accWhite,
    required this.accBlack,
    required this.acplWhite,
    required this.acplBlack,
    required this.phaseAccuracy,
    required this.counts,
    required this.presetId,
    required this.engineVersion,
  });

  Map<String, dynamic> toMap() => {
        'game_id': gameId,
        'acc_white': accWhite,
        'acc_black': accBlack,
        'acpl_white': acplWhite,
        'acpl_black': acplBlack,
        'phase_accuracy_json': jsonEncode(phaseAccuracy),
        'counts_json': jsonEncode(counts),
        'preset_id': presetId,
        'engine_version': engineVersion,
      };

  factory GameSummaryEntity.fromMap(Map<String, dynamic> map) {
    final rawPhase =
        jsonDecode((map['phase_accuracy_json'] as String?) ?? '{}')
            as Map<String, dynamic>;
    final rawCounts =
        jsonDecode((map['counts_json'] as String?) ?? '{}')
            as Map<String, dynamic>;
    return GameSummaryEntity(
      gameId: map['game_id'] as String,
      accWhite: (map['acc_white'] as num?)?.toDouble() ?? 0.0,
      accBlack: (map['acc_black'] as num?)?.toDouble() ?? 0.0,
      acplWhite: (map['acpl_white'] as num?)?.toDouble() ?? 0.0,
      acplBlack: (map['acpl_black'] as num?)?.toDouble() ?? 0.0,
      phaseAccuracy: rawPhase.map(
        (k, v) => MapEntry(
          k,
          (v as Map<String, dynamic>).map(
            (pk, pv) => MapEntry(pk, (pv as num).toDouble()),
          ),
        ),
      ),
      counts: rawCounts.map(
        (k, v) => MapEntry(
          k,
          (v as Map<String, dynamic>).map(
            (ck, cv) => MapEntry(ck, (cv as num).toInt()),
          ),
        ),
      ),
      presetId: (map['preset_id'] as String?) ?? 'lichess',
      engineVersion: (map['engine_version'] as String?) ?? 'Stockfish-16.1',
    );
  }
}

class TagEntity {
  final String gameId;
  final int ply;
  final String code;
  final String side; // 'played' or 'best' (Part 24)
  final Map<String, String> params;
  final Map<String, dynamic> evidence;
  final String ruleVersion;

  const TagEntity({
    required this.gameId,
    required this.ply,
    required this.code,
    this.side = 'played',
    this.params = const {},
    this.evidence = const {},
    this.ruleVersion = 'v1.0',
  });

  /// Part 22.1: Renders `CODE(key=value; ...)` for CoachRequest.
  String toCompactString() {
    final entries = <String>['side=$side'];
    params.forEach((k, v) {
      entries.add('$k=$v');
    });
    return '$code(${entries.join('; ')})';
  }

  Map<String, dynamic> toMap() => {
        'game_id': gameId,
        'ply': ply,
        'code': code,
        'params_json': jsonEncode({...params, 'side': side, 'v': ruleVersion}),
        'evidence_json': jsonEncode(evidence),
      };

  factory TagEntity.fromMap(Map<String, dynamic> map) {
    final rawParams =
        jsonDecode((map['params_json'] as String?) ?? '{}')
            as Map<String, dynamic>;
    final side = (rawParams['side'] as String?) ?? 'played';
    final rv = (rawParams['v'] as String?) ?? 'v1.0';
    final cleanParams = <String, String>{};
    rawParams.forEach((k, v) {
      if (k != 'side' && k != 'v') cleanParams[k] = v.toString();
    });
    return TagEntity(
      gameId: map['game_id'] as String,
      ply: map['ply'] as int,
      code: map['code'] as String,
      side: side,
      params: cleanParams,
      evidence: jsonDecode((map['evidence_json'] as String?) ?? '{}')
          as Map<String, dynamic>,
      ruleVersion: rv,
    );
  }
}

class CriticalMomentEntity {
  final String gameId;
  final int ply;
  final int rank;
  final String reason;
  final List<TagEntity> tags;

  const CriticalMomentEntity({
    required this.gameId,
    required this.ply,
    required this.rank,
    required this.reason,
    this.tags = const [],
  });

  Map<String, dynamic> toMap() => {
        'game_id': gameId,
        'ply': ply,
        'rank': rank,
        'reason': reason,
        'tags_json': jsonEncode(tags.map((t) => t.toMap()).toList()),
      };

  factory CriticalMomentEntity.fromMap(Map<String, dynamic> map) {
    final rawTags =
        jsonDecode((map['tags_json'] as String?) ?? '[]') as List<dynamic>;
    return CriticalMomentEntity(
      gameId: map['game_id'] as String,
      ply: map['ply'] as int,
      rank: map['rank'] as int,
      reason: map['reason'] as String,
      tags: rawTags
          .map((e) => TagEntity.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}
