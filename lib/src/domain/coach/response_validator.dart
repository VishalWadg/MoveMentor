import 'dart:convert';
import 'package:chess/chess.dart' as ch;
import '../chess/chess_models.dart';
import 'coach_contracts.dart';

enum ValidationVerdictType {
  ok,
  repaired,
  retry,
  fallback,
}

class ValidationResult {
  final ValidationVerdictType verdict;
  final CoachResponse? response;
  final String? failureCode;
  final String? retryReason;
  final String? softWarning;

  const ValidationResult({
    required this.verdict,
    this.response,
    this.failureCode,
    this.retryReason,
    this.softWarning,
  });

  bool get isAccepted =>
      verdict == ValidationVerdictType.ok ||
      verdict == ValidationVerdictType.repaired;
}

/// Part 22.5: Provider-agnostic 12-step Validator algorithm (BR-4, FR-05).
class CoachResponseValidator {
  static const List<String> _positivePolarityWords = [
    'brilliant',
    'great move',
    'excellent move',
    'best move',
    'perfect move',
    'winning move',
  ];

  static const List<String> _negativePolarityWords = [
    'blunder',
    'terrible mistake',
    'losing move',
    'fatal error',
    'awful',
  ];

  static const List<String> _bannedShamingOrNonChess = [
    'stupid',
    'idiot',
    'hopeless',
    'quit chess',
    'medical advice',
    'financial advice',
    'doctor',
  ];

  static const List<String> _noviceJargonWords = [
    'prophylaxis',
    'zwischenzug',
    'zugzwang',
    'hypermodern',
    'triangulation',
  ];

  static ValidationResult validate(
    String rawOutput,
    CoachRequest req, {
    required String providerId,
  }) {
    var wasRepaired = false;

    // Step 1: Extract and repair: strip code fences, take the first balanced {...}
    final extracted = _extractFirstBalancedJson(rawOutput);
    if (extracted == null) {
      return const ValidationResult(
        verdict: ValidationVerdictType.retry,
        failureCode: 'VAL_JSON_EXTRACT',
        retryReason: 'Output must be a single valid JSON object starting with { and ending with }.',
      );
    }
    if (extracted != rawOutput.trim()) {
      wasRepaired = true;
    }

    // Step 2: Parse JSON; on failure go to step 11
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(extracted) as Map<String, dynamic>;
    } catch (_) {
      return const ValidationResult(
        verdict: ValidationVerdictType.retry,
        failureCode: 'VAL_JSON_PARSE',
        retryReason: 'Malformed JSON syntax. Output only valid JSON with double-quoted strings.',
      );
    }

    // Step 3: Overwrite move, classification, win_equity_drop with engine facts
    parsed['move'] = req.moveSan;
    parsed['classification'] = req.classification.label;
    parsed['win_equity_drop'] =
        double.parse(req.deltaW.toStringAsFixed(1));

    // Step 4: Check required fields and length limits (Part 22.2: 160 / 480 / 160 / 100)
    final tacticalSummary = (parsed['tactical_summary'] ?? '').toString().trim();
    final coachCommentary = (parsed['coach_commentary'] ?? '').toString().trim();
    var betterIdea = (parsed['better_idea'] ?? '').toString().trim();
    final lesson = (parsed['lesson'] ?? '').toString().trim();

    if (tacticalSummary.isEmpty ||
        coachCommentary.isEmpty ||
        betterIdea.isEmpty ||
        lesson.isEmpty) {
      return const ValidationResult(
        verdict: ValidationVerdictType.retry,
        failureCode: 'VAL_MISSING_FIELD',
        retryReason:
            'All four text fields (tactical_summary, coach_commentary, better_idea, lesson) must be non-empty.',
      );
    }

    if (tacticalSummary.length > 160 ||
        coachCommentary.length > 480 ||
        betterIdea.length > 160 ||
        lesson.length > 100) {
      return const ValidationResult(
        verdict: ValidationVerdictType.retry,
        failureCode: 'VAL_LENGTH_LIMIT',
        retryReason:
            'Length exceeded: keep tactical_summary <= 160 chars, coach_commentary <= 480 chars, better_idea <= 160 chars, lesson <= 100 chars.',
      );
    }

    // Part 22.2: better_idea must reference the supplied best move (or its target square/piece)
    final bestMove = req.bestMoveSan.trim();
    if (bestMove.isNotEmpty &&
        !betterIdea.toLowerCase().contains(bestMove.toLowerCase())) {
      final destMatch = RegExp(r'([a-h][1-8])').allMatches(bestMove);
      final destSq = destMatch.isNotEmpty ? destMatch.last.group(1)! : '';
      if (destSq.isEmpty || !betterIdea.toLowerCase().contains(destSq)) {
        // Auto-repair better_idea if missing best move reference
        final trimmedIdea = betterIdea.endsWith('.')
            ? betterIdea.substring(0, betterIdea.length - 1)
            : betterIdea;
        final candidate = '$trimmedIdea ($bestMove).';
        if (candidate.length <= 160) {
          betterIdea = candidate;
          wasRepaired = true;
        } else {
          return ValidationResult(
            verdict: ValidationVerdictType.retry,
            failureCode: 'VAL_MISSING_BEST_MOVE',
            retryReason:
                'The better_idea field must explicitly reference the best move $bestMove.',
          );
        }
      }
    }

    final combinedText =
        '$tacticalSummary $coachCommentary $betterIdea $lesson';

    // Step 5 & 6: Collect explicit SAN tokens and verify legality in root position or supplied PV
    final allowedSanMoves = _collectLegalMovesInRootAndPv(req);
    final mentionedSans = _extractExplicitSanTokens(combinedText);
    for (final token in mentionedSans) {
      final clean = token.replaceAll(RegExp(r'[+#!?]+$'), '');
      if (!allowedSanMoves.contains(clean)) {
        return ValidationResult(
          verdict: ValidationVerdictType.retry,
          failureCode: 'VAL_ILLEGAL_MOVE',
          retryReason:
              'Move "$token" is not legal in the position or supplied best line. Mention only ${req.moveSan} or ${req.bestMoveSan}.',
        );
      }
    }

    // Step 7: Existence: every named "piece on square" phrase must exist in root or along PV
    final pieceOnSquareErrors = _checkPieceOnSquareExistence(combinedText, req);
    if (pieceOnSquareErrors != null) {
      return ValidationResult(
        verdict: ValidationVerdictType.retry,
        failureCode: 'VAL_NONEXISTENT_PIECE_SQUARE',
        retryReason: pieceOnSquareErrors,
      );
    }

    // Step 8: Consistency: reject polarity words that contradict the label
    final lowerText = combinedText.toLowerCase();
    if (req.classification.isNegative) {
      for (final posWord in _positivePolarityWords) {
        if (lowerText.contains(posWord)) {
          return ValidationResult(
            verdict: ValidationVerdictType.retry,
            failureCode: 'VAL_POLARITY_CONTRADICTION',
            retryReason:
                'Move was labelled ${req.classification.label}; do not call it "$posWord".',
          );
        }
      }
    } else if (req.classification.isPositive) {
      for (final negWord in _negativePolarityWords) {
        // Allow saying "avoids a blunder"
        if (lowerText.contains(negWord) && !lowerText.contains('avoid')) {
          return ValidationResult(
            verdict: ValidationVerdictType.retry,
            failureCode: 'VAL_POLARITY_CONTRADICTION',
            retryReason:
                'Move was labelled ${req.classification.label}; do not describe it as "$negWord".',
          );
        }
      }
    }

    // Step 9: Banned content: shaming terms, opponent rating claims, non-chess advice
    for (final banned in _bannedShamingOrNonChess) {
      if (lowerText.contains(banned)) {
        return ValidationResult(
          verdict: ValidationVerdictType.fallback,
          failureCode: 'VAL_BANNED_CONTENT',
          retryReason: 'Contains banned or off-topic phrase "$banned".',
        );
      }
    }
    if (RegExp(r'opponent\s+(?:is\s+)?rated\s+\d+').hasMatch(lowerText)) {
      return const ValidationResult(
        verdict: ValidationVerdictType.retry,
        failureCode: 'VAL_OPPONENT_RATING_CLAIM',
        retryReason: 'Never state or guess player ratings.',
      );
    }

    // Step 10: Soft checks only: reading level for the band
    String? softWarning;
    if (req.ratingBand == RatingBand.novice) {
      for (final jargon in _noviceJargonWords) {
        if (lowerText.contains(jargon)) {
          softWarning = 'Novice text used advanced jargon "$jargon".';
          break;
        }
      }
    }

    // Step 11: Return verdict (ok or repaired)
    final finalResp = CoachResponse(
      move: req.moveSan,
      classification: req.classification.label,
      winEquityDrop: double.parse(req.deltaW.toStringAsFixed(1)),
      tacticalSummary: tacticalSummary,
      coachCommentary: coachCommentary,
      betterIdea: betterIdea,
      lesson: lesson,
      providerId: providerId,
      isFallback: false,
    );

    return ValidationResult(
      verdict: wasRepaired
          ? ValidationVerdictType.repaired
          : ValidationVerdictType.ok,
      response: finalResp,
      softWarning: softWarning,
    );
  }

  static String? _extractFirstBalancedJson(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'```(?:json)?', caseSensitive: false), '')
        .replaceAll('```', '')
        .trim();
    final start = cleaned.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inQuotes = false;
    var escaped = false;
    for (var i = start; i < cleaned.length; i++) {
      final c = cleaned[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == r'\') {
        escaped = true;
        continue;
      }
      if (c == '"') {
        inQuotes = !inQuotes;
        continue;
      }
      if (!inQuotes) {
        if (c == '{') depth++;
        if (c == '}') {
          depth--;
          if (depth == 0) {
            return cleaned.substring(start, i + 1);
          }
        }
      }
    }
    return null;
  }

  static Set<String> _collectLegalMovesInRootAndPv(CoachRequest req) {
    final allowed = <String>{
      req.moveSan.replaceAll(RegExp(r'[+#!?]+$'), ''),
      req.bestMoveSan.replaceAll(RegExp(r'[+#!?]+$'), ''),
      for (final m in req.bestLineSan) m.replaceAll(RegExp(r'[+#!?]+$'), ''),
      if (req.secondBestSan != null)
        req.secondBestSan!.replaceAll(RegExp(r'[+#!?]+$'), ''),
    };

    try {
      final game = ch.Chess.fromFEN(req.fen);
      for (final m in game.generate_moves()) {
        allowed.add(game.move_to_san(m).replaceAll(RegExp(r'[+#!?]+$'), ''));
      }
      // Also walk played move and best line to allow legal replies
      for (final san in req.bestLineSan.take(4)) {
        final match = game
            .generate_moves()
            .where((m) =>
                game.move_to_san(m).replaceAll(RegExp(r'[+#!?]+$'), '') ==
                san.replaceAll(RegExp(r'[+#!?]+$'), ''))
            .firstOrNull;
        if (match == null) break;
        game.move(match);
        for (final m in game.generate_moves()) {
          allowed.add(game.move_to_san(m).replaceAll(RegExp(r'[+#!?]+$'), ''));
        }
      }
    } catch (_) {}
    return allowed;
  }

  static List<String> _extractExplicitSanTokens(String text) {
    // Matches explicit piece SAN moves like Nf3, Qxb7, Rae1, O-O, exd5
    final regex = RegExp(
      r'\b([KQRBN][a-h]?[1-8]?x?[a-h][1-8](?:=[QRBN])?[+#]?|[a-h]x[a-h][1-8](?:=[QRBN])?[+#]?|O-O-O|O-O)\b',
    );
    return regex.allMatches(text).map((m) => m.group(1)!).toList();
  }

  static String? _checkPieceOnSquareExistence(String text, CoachRequest req) {
    final phraseRegex = RegExp(
      r'\b(king|queen|rook|bishop|knight|pawn)\s+on\s+([a-h][1-8])\b',
      caseSensitive: false,
    );
    final matches = phraseRegex.allMatches(text).toList();
    if (matches.isEmpty) return null;

    // Collect valid (piece, square) pairs across root position, after played move, and along PV
    final validPairs = <String>{};
    for (final t in req.tags) {
      t.params.forEach((_, v) {
        final m = phraseRegex.firstMatch(v);
        if (m != null) {
          validPairs.add('${m.group(1)!.toLowerCase()}@${m.group(2)!.toLowerCase()}');
        }
      });
      final p = t.params['piece']?.toLowerCase();
      final sq = t.params['square']?.toLowerCase();
      if (p != null && sq != null) validPairs.add('$p@$sq');
    }

    try {
      final game = ch.Chess.fromFEN(req.fen);
      _recordBoardPieces(game, validPairs);
      // After played move
      for (final m in game.generate_moves()) {
        if (game.move_to_san(m).replaceAll(RegExp(r'[+#!?]+$'), '') ==
            req.moveSan.replaceAll(RegExp(r'[+#!?]+$'), '')) {
          game.move(m);
          _recordBoardPieces(game, validPairs);
          break;
        }
      }
      // Along best line from root
      final pvGame = ch.Chess.fromFEN(req.fen);
      for (final san in req.bestLineSan.take(6)) {
        for (final m in pvGame.generate_moves()) {
          if (pvGame.move_to_san(m).replaceAll(RegExp(r'[+#!?]+$'), '') ==
              san.replaceAll(RegExp(r'[+#!?]+$'), '')) {
            pvGame.move(m);
            _recordBoardPieces(pvGame, validPairs);
            break;
          }
        }
      }
    } catch (_) {}

    for (final m in matches) {
      final piece = m.group(1)!.toLowerCase();
      final sq = m.group(2)!.toLowerCase();
      if (!validPairs.contains('$piece@$sq')) {
        return 'No $piece exists on $sq in the position or principal variation.';
      }
    }
    return null;
  }

  static void _recordBoardPieces(ch.Chess game, Set<String> out) {
    for (var i = 0; i < 128; i++) {
      if ((i & 0x88) != 0) continue;
      final p = game.board[i];
      if (p == null) continue;
      final sq = ch.Chess.algebraic(i).toLowerCase();
      final name = _typeToWord(p.type);
      out.add('$name@$sq');
    }
  }

  static String _typeToWord(ch.PieceType t) {
    switch (t) {
      case ch.PieceType.KING:
        return 'king';
      case ch.PieceType.QUEEN:
        return 'queen';
      case ch.PieceType.ROOK:
        return 'rook';
      case ch.PieceType.BISHOP:
        return 'bishop';
      case ch.PieceType.KNIGHT:
        return 'knight';
      default:
        return 'pawn';
    }
  }
}
