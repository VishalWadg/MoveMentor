import 'dart:convert';
import '../chess/chess_models.dart';

/// Part 8.3 & 12.2: Provider capabilities and status.
class ProviderCapabilities {
  final bool supportsStreaming;
  final int maxContextTokens;
  final bool supportsJsonMode;
  final bool supportsGrammar;
  final bool isRemote;

  const ProviderCapabilities({
    required this.supportsStreaming,
    required this.maxContextTokens,
    required this.supportsJsonMode,
    required this.supportsGrammar,
    required this.isRemote,
  });
}

enum ProviderStatusType {
  ready,
  needsModel,
  needsNetwork,
  misconfigured,
}

class ProviderStatus {
  final ProviderStatusType status;
  final String? message;
  final String? errorCode;

  const ProviderStatus({
    required this.status,
    this.message,
    this.errorCode,
  });

  bool get isReady => status == ProviderStatusType.ready;
}

class CancelToken {
  bool _isCancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _isCancelled;

  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    final snapshot = List<void Function()>.from(_listeners);
    _listeners.clear();
    for (final listener in snapshot) {
      listener();
    }
  }
}

/// Part 12.3 & 22.1: CoachRequest passed identically to all ExplanationProviders.
/// Player names, event, site, and PGN comments are NEVER included (R-12 / Part 23.5).
class CoachRequest {
  final String gameId;
  final RatingBand ratingBand;
  final SideColor userColor;
  final int ply;
  final String fen;
  final String moveSan;
  final MoveClassification classification;
  final double winBefore;
  final double winAfter;
  final double deltaW;
  final String bestMoveSan;
  final List<String> bestLineSan; // Up to 6 plies
  final String? secondBestSan;
  final GamePhase phase;
  final int materialChange;
  final List<TagEntity> tags; // Up to 4 ranked tags
  final String? openingName;
  final String language;
  final String? followUpQuestion;

  const CoachRequest({
    required this.gameId,
    required this.ratingBand,
    required this.userColor,
    required this.ply,
    required this.fen,
    required this.moveSan,
    required this.classification,
    required this.winBefore,
    required this.winAfter,
    required this.deltaW,
    required this.bestMoveSan,
    this.bestLineSan = const [],
    this.secondBestSan,
    required this.phase,
    this.materialChange = 0,
    this.tags = const [],
    this.openingName,
    this.language = 'en',
    this.followUpQuestion,
  });

  /// Part 22.1: Renders CoachRequest as compact key-value text (never raw PGN or player names).
  String renderCompactKeyValue({bool includeFen = true, bool includeOpening = false}) {
    final bestLineStr = bestLineSan.take(6).join(' ');
    final tagsStr = tags.isEmpty
        ? 'none'
        : tags.take(4).map((t) => t.toCompactString()).join(', ');
    final buf = StringBuffer()
      ..writeln('band: ${ratingBand.label}')
      ..writeln('user_color: ${userColor.label}')
      ..writeln('ply: $ply')
      ..writeln('played: $moveSan')
      ..writeln('label: ${classification.label}')
      ..writeln('win_before: ${winBefore.toStringAsFixed(1)}')
      ..writeln('win_after: ${winAfter.toStringAsFixed(1)}')
      ..writeln('drop: ${deltaW.toStringAsFixed(1)}')
      ..writeln('best: ${bestMoveSan.isEmpty ? moveSan : bestMoveSan}')
      ..writeln('best_line: ${bestLineStr.isEmpty ? (bestMoveSan.isEmpty ? moveSan : bestMoveSan) : bestLineStr}')
      ..writeln('second_best: ${secondBestSan ?? 'none'}')
      ..writeln('phase: ${phase.label}')
      ..writeln('material_change: $materialChange')
      ..writeln('tags: $tagsStr');
    if (includeOpening && openingName != null && openingName!.isNotEmpty) {
      buf.writeln('opening: $openingName');
    }
    if (includeFen) {
      buf.write('position_fen: $fen');
    }
    return buf.toString().trim();
  }
}

/// Part 12.3 & 22.2: CoachResponse contract (7 fields; first 3 overwritten with engine facts).
class CoachResponse {
  final String move;
  final String classification;
  final double winEquityDrop;
  final String tacticalSummary; // 1 sentence, <= 160 chars
  final String coachCommentary; // 2-4 sentences, <= 480 chars
  final String betterIdea; // 1 sentence, <= 160 chars, references best move
  final String lesson; // <= 100 chars
  final String providerId;
  final bool isFallback;
  final String? debugReason;

  const CoachResponse({
    required this.move,
    required this.classification,
    required this.winEquityDrop,
    required this.tacticalSummary,
    required this.coachCommentary,
    required this.betterIdea,
    required this.lesson,
    this.providerId = 'template',
    this.isFallback = false,
    this.debugReason,
  });

  Map<String, dynamic> toJson() => {
        'move': move,
        'classification': classification,
        'win_equity_drop': double.parse(winEquityDrop.toStringAsFixed(1)),
        'tactical_summary': tacticalSummary,
        'coach_commentary': coachCommentary,
        'better_idea': betterIdea,
        'lesson': lesson,
      };

  String toJsonString() => jsonEncode(toJson());

  factory CoachResponse.fromJson(
    Map<String, dynamic> json, {
    String providerId = 'template',
    bool isFallback = false,
    String? debugReason,
  }) =>
      CoachResponse(
        move: (json['move'] ?? '').toString(),
        classification: (json['classification'] ?? '').toString(),
        winEquityDrop: (json['win_equity_drop'] as num?)?.toDouble() ?? 0.0,
        tacticalSummary: (json['tactical_summary'] ?? '').toString(),
        coachCommentary: (json['coach_commentary'] ?? '').toString(),
        betterIdea: (json['better_idea'] ?? '').toString(),
        lesson: (json['lesson'] ?? '').toString(),
        providerId: providerId,
        isFallback: isFallback,
        debugReason: debugReason,
      );
}

class CoachChunk {
  final String deltaText;
  final CoachResponse? finalResponse;
  final bool isDone;

  const CoachChunk({
    required this.deltaText,
    this.finalResponse,
    this.isDone = false,
  });
}
