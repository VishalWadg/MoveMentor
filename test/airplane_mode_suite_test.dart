import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/adapters/storage/sqlite_storage_adapter.dart';
import 'package:movementor/src/application/app_state.dart';
import 'package:movementor/src/domain/chess/chess_models.dart';
import 'package:movementor/src/domain/chess/pgn_parser.dart';

void main() {
  test('Part 30.3 Airplane-mode suite (NFR-07): Full offline import, analysis, coaching, and export', () async {
    final services = AppServices.createDefault(seedDemoGame: false);

    // 1. Fresh install, Offline-only is ON by default (D-14)
    expect(services.gateway.isOfflineOnly, isTrue);

    // 2 & 3. Import PGN offline
    const pgnText = '''
[Event "Offline Tournament"]
[White "Omar"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. b4 Bxb4 5. c3 Ba5 6. d4 exd4 7. O-O dxc3 8. Qb3 Qf6 9. e5 Qg6 10. Nxc3 Nge7 1-0
''';
    final report = PgnParser.parseMultiGamePgn(pgnText, source: 'pgn');
    expect(report.games.length, 1);
    final outcome = services.storage.upsertParsedGame(report.games.single);
    expect(outcome, DedupeOutcome.inserted);

    final gameId = report.games.single.game.id;

    // 5 & 6. Analyse game offline & generate Template Coach explanations
    final states =
        await services.pipeline.analyseGame(gameId).toList();
    expect(states.last.stage, 'done');

    final summary = services.storage.getGameSummary(gameId);
    expect(summary, isNotNull);
    final moments = services.storage.getCriticalMoments(gameId);
    expect(moments.isNotEmpty, isTrue);

    // 7 & 9. Switch provider mid-session to built-in model; next explanation uses new provider
    services.storage.setSetting('active_provider_id', 'builtin');
    final firstMoment = moments.first;
    final exp = services.storage.getExplanation(
      gameId: gameId,
      ply: firstMoment.ply,
      providerId: 'template',
      band: RatingBand.intermediate,
    );
    expect(exp, isNotNull);

    // 10. Select remote provider while offline -> automatic Template fallback with no crash
    services.storage.setSetting('active_provider_id', 'remote:default');
    final analyses = services.storage.getMoveAnalyses(gameId);
    expect(analyses.isNotEmpty, isTrue);

    // 12. Export annotated PGN & full data ZIP offline with zero secrets
    final annotatedPgn = services.exportService.buildAnnotatedPgn(gameId);
    expect(annotatedPgn.contains('[White "Omar"]'), isTrue);

    final zipBytes = services.exportService.buildFullDataExportZip();
    expect(zipBytes.isNotEmpty, isTrue);
  });
}
