import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/adapters/network/network_gateway_adapter.dart';
import 'package:movementor/src/adapters/providers/llama_and_remote_providers.dart';
import 'package:movementor/src/adapters/providers/template_coach_provider.dart';
import 'package:movementor/src/domain/chess/chess_models.dart';
import 'package:movementor/src/domain/coach/coach_contracts.dart';
import 'package:movementor/src/domain/coach/gbnf_grammar.dart';
import 'package:movementor/src/domain/coach/response_validator.dart';

void main() {
  const sampleReq = CoachRequest(
    gameId: 'game_1',
    ratingBand: RatingBand.novice,
    userColor: SideColor.w,
    ply: 23,
    fen: '1rbqkbnr/p1pp1ppp/2n5/4p3/4P3/1Q3N2/PPPP1PPP/RNB1KB1R w KQkq - 1 5',
    moveSan: 'Qxb7',
    classification: MoveClassification.blunder,
    winBefore: 62.0,
    winAfter: 31.5,
    deltaW: 30.5,
    bestMoveSan: 'Bc4',
    bestLineSan: ['Bc4', 'Nf6'],
    phase: GamePhase.middlegame,
    materialChange: -9,
    tags: [
      TagEntity(
        gameId: 'game_1',
        ply: 23,
        code: 'HANGING_PIECE',
        params: {
          'side': 'white',
          'piece': 'queen',
          'square': 'b7',
          'attacked_by': 'rook on b8',
          'defended': 'no',
        },
      ),
    ],
  );

  group('Part 22.5 Validator & Part 30.4 Provider Contract Suite', () {
    test('T-AI-01..03: Validator accepts valid response, rejects illegal move and polarity contradiction', () {
      const validRaw = '''
```json
{
  "move": "wrong_echo",
  "classification": "Good",
  "win_equity_drop": 0.0,
  "tactical_summary": "Your queen took a pawn on b7 where the black rook on b8 can capture it.",
  "coach_commentary": "You won a pawn, but the rook on b8 can take your queen for free. Before you capture, check if the piece is defended.",
  "better_idea": "Developing the bishop with Bc4 keeps your queen safe.",
  "lesson": "Check if your piece can be captured before moving it."
}
```
''';
      final res = CoachResponseValidator.validate(
        validRaw,
        sampleReq,
        providerId: 'builtin',
      );
      expect(res.isAccepted, isTrue);
      // Step 3: Overwrites move, classification, win_equity_drop with engine truth
      expect(res.response!.move, 'Qxb7');
      expect(res.response!.classification, 'Blunder');
      expect(res.response!.winEquityDrop, 30.5);

      // Illegal move mention (Qh8 is illegal) -> rejected
      const illegalMoveJson = '''
{"move":"Qxb7","classification":"Blunder","win_equity_drop":30.5,"tactical_summary":"Playing Qh8 was better.","coach_commentary":"You played Qxb7 instead of Qh8.","better_idea":"Play Bc4 instead.","lesson":"Watch your pieces."}
''';
      final resIllegal = CoachResponseValidator.validate(
        illegalMoveJson,
        sampleReq,
        providerId: 'builtin',
      );
      expect(resIllegal.isAccepted, isFalse);
      expect(resIllegal.failureCode, 'VAL_ILLEGAL_MOVE');

      // Polarity contradiction ("great move" on a Blunder) -> rejected
      const contradictionJson = '''
{"move":"Qxb7","classification":"Blunder","win_equity_drop":30.5,"tactical_summary":"That was a great move on b7.","coach_commentary":"You found a great move.","better_idea":"Bc4 was also fine.","lesson":"Keep attacking."}
''';
      final resContra = CoachResponseValidator.validate(
        contradictionJson,
        sampleReq,
        providerId: 'builtin',
      );
      expect(resContra.isAccepted, isFalse);
      expect(resContra.failureCode, 'VAL_POLARITY_CONTRADICTION');
    });

    test('Part 25: Template Coach covers all combinations with zero unfilled slots & passes validator', () {
      final templateCoach = TemplateCoachProvider();
      for (final band in RatingBand.values) {
        for (final cls in MoveClassification.values) {
          for (final tagCode in TemplateCoachProvider.s1ByTag.keys) {
            final req = CoachRequest(
              gameId: 'test_game',
              ratingBand: band,
              userColor: SideColor.w,
              ply: 15,
              fen: sampleReq.fen,
              moveSan: 'Qxb7',
              classification: cls,
              winBefore: 55.0,
              winAfter: 40.0,
              deltaW: 15.0,
              bestMoveSan: 'Bc4',
              bestLineSan: const ['Bc4'],
              phase: GamePhase.middlegame,
              tags: [
                TagEntity(
                  gameId: 'test_game',
                  ply: 15,
                  code: tagCode,
                  params: const {
                    'piece': 'queen',
                    'square': 'b7',
                    'attacked_by': 'rook on b8',
                    'targets': 'king and rook',
                  },
                ),
              ],
            );
            final resp = templateCoach.buildDeterministicResponse(req);
            final combined =
                '${resp.tacticalSummary} ${resp.coachCommentary} ${resp.betterIdea} ${resp.lesson}';
            expect(combined.contains('{'), isFalse);
            expect(combined.contains('}'), isFalse);
            expect(resp.tacticalSummary.length <= 160, isTrue);
            expect(resp.coachCommentary.length <= 480, isTrue);
            expect(resp.betterIdea.length <= 160, isTrue);
            expect(resp.lesson.length <= 100, isTrue);
          }
        }
      }
    });

    test('Part 22.3 & 30.4: GBNF Grammar Builder and Offline-only Gateway Block (T-NET-02)', () {
      final grammar = GbnfGrammarBuilder.buildForRequest(sampleReq);
      expect(grammar.contains('"Qxb7"'), isTrue);
      expect(grammar.contains('"Blunder"'), isTrue);
      expect(grammar.contains('"30.5"'), isTrue);

      final gateway = NetworkGatewayAdapter(initialOfflineOnly: true);
      final remote = RemoteApiProvider(
        id: 'remote:test',
        displayName: 'Test API',
        baseUrl: 'https://api.openai.com/v1',
        modelName: 'gpt-4o-mini',
        secretRef: 'sec_1',
        gateway: gateway,
        secureStore: SecureStoreAdapter(useMemoryOnly: true),
      );

      expect(
        () => remote.explain(sampleReq).toList(),
        throwsA(isA<StateError>()),
      );
      expect(gateway.auditLogs.single.blockedByOfflineOnly, isTrue);
    });
  });
}
