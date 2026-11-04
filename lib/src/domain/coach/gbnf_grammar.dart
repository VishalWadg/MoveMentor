import 'coach_contracts.dart';

/// Part 22.3: Dynamic GBNF Grammar Builder for llama.cpp providers.
/// Replaces MOVE, LABEL, and DROP with the engine's true values as literals,
/// so the model generates only the four text fields and saves ~40 output tokens.
class GbnfGrammarBuilder {
  static String buildForRequest(
    CoachRequest req, {
    bool useRepetitionBounds = true,
  }) {
    final safeMove = req.moveSan.replaceAll('"', '').replaceAll(r'\', '');
    final safeLabel = req.classification.label;
    final safeDrop = req.deltaW.toStringAsFixed(1);

    final s160Rule =
        useRepetitionBounds ? 'q char{1,160} q' : 'q char+ q';
    final s480Rule =
        useRepetitionBounds ? 'q char{1,480} q' : 'q char+ q';
    final s100Rule =
        useRepetitionBounds ? 'q char{1,100} q' : 'q char+ q';

    return '''
root ::= "{" ws q "move" q ":" ws q "$safeMove" q "," ws q "classification" q ":" ws q "$safeLabel" q "," ws q "win_equity_drop" q ":" ws "$safeDrop" "," ws q "tactical_summary" q ":" ws s160 "," ws q "coach_commentary" q ":" ws s480 "," ws q "better_idea" q ":" ws s160 "," ws q "lesson" q ":" ws s100 ws "}"
q ::= ["]
ws ::= [ \n]{0,2}
char ::= [^"\\\n]
s160 ::= $s160Rule
s480 ::= $s480Rule
s100 ::= $s100Rule
'''.trim();
  }
}
