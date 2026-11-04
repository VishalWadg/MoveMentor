import '../chess/chess_models.dart';
import 'coach_contracts.dart';

/// Part 23: Prompt library (System prompt v1, Band blocks, Few-shot examples, Follow-up prompt, Injection hygiene).
class PromptLibrary {
  static const Map<RatingBand, String> bandBlocks = {
    RatingBand.novice:
        'Short sentences, everyday words. Say what happened first, then what to do next time. Talk about pieces that can be captured, checks and king safety. No theory words. Maximum 3 sentences.',
    RatingBand.intermediate:
        'Name the tactic in plain terms (fork, pin). Mention piece coordination or tempo when the tags support it. Maximum 4 sentences.',
    RatingBand.advanced:
        'Use strategic terms where tags support them (lever, weak square, activity). Skip basic tactics explanations. Maximum 4 sentences.',
    RatingBand.master:
        'Concrete and brief. Point to the move-order or conversion issue. No hand-holding. Maximum 3 sentences.',
  };

  /// Part 23.3: Novice few-shot example plus reference examples per band.
  static const String noviceFewShotOutput =
      '{"move":"Qxb7","classification":"Blunder","win_equity_drop":30.5,"tactical_summary":"Your queen took a pawn on b7 where the black rook can capture it.","coach_commentary":"You won a pawn, but the rook on b8 can take your queen for free. The queen is worth much more than a pawn. Before you capture, ask: can the piece be taken back?","better_idea":"Developing the knight with Nf3 keeps your queen safe.","lesson":"Check if your piece can be captured before you move it."}';

  /// Part 23.1: System prompt v1 (all providers).
  static String buildSystemPrompt(CoachRequest req, {String? retryReminder}) {
    final bandBlock = bandBlocks[req.ratingBand] ?? bandBlocks[RatingBand.novice]!;
    final base = '''
You are a chess coach inside a mobile app. A chess engine has already analysed the position.
Explain only the facts you are given.
1. Use only moves, squares and pieces that appear in the facts. Never invent a move.
2. Do not calculate or search. If unsure, say less.
3. Do not state any evaluation number that is not given.
4. The move was labelled ${req.classification.label}. Never describe it as a different quality.
5. Style for ${req.ratingBand.label}: $bandBlock
6. Output only the JSON object. No other text.
Example valid JSON output:
$noviceFewShotOutput
'''
        .trim();

    if (retryReminder != null && retryReminder.isNotEmpty) {
      return '$base\nIMPORTANT CORRECTION: $retryReminder';
    }
    return base;
  }

  /// Part 23.4: Follow-up prompt (Story E-7).
  static String buildFollowUpPrompt(CoachRequest req, String question) {
    final sys = buildSystemPrompt(req);
    return '''
$sys
The student asks: $question. Answer in at most 3 sentences using only the facts above. If the question needs new calculation, say you cannot calculate and suggest tapping an alternative move to have the engine check it.
''';
  }
}
