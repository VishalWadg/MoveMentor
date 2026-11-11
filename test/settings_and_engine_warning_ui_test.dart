import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/adapters/engine/stockfish_engine_adapter.dart';
import 'package:movementor/src/application/app_state.dart';
import 'package:movementor/src/application/export_service.dart';
import 'package:movementor/src/domain/chess/chess_models.dart';
import 'package:movementor/src/presentation/screens/movementor_screens.dart';

class _StubHealthyStockfishAdapter extends StockfishEngineAdapter {
  _StubHealthyStockfishAdapter() : super(refuseSilentFallback: true);

  @override
  bool get isHealthy => true;

  @override
  bool get isFallbackEngine => false;

  @override
  String get engineVersion => 'Stockfish 19 (TestHealthy)';
}

void main() {
  group('Settings UI toggle & unreliable-engine warning banners', () {
    testWidgets(
      'SettingsHubScreen toggles useNewClassifier and persists to storage/pipeline',
      (tester) async {
        final services = AppServices.createDefault(
          seedDemoGame: false,
          autoDiscoverDesktopStockfish: false,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: const MaterialApp(
              home: Scaffold(body: SettingsHubScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final toggleFinder =
            find.byKey(const Key('use_new_classifier_switch'));
        await tester.scrollUntilVisible(
          toggleFinder,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(toggleFinder, findsOneWidget);
        expect(
          tester.widget<SwitchListTile>(toggleFinder).value,
          isTrue,
        );
        expect(services.pipeline.resolveUseNewClassifier(), isTrue);

        await tester.tap(toggleFinder);
        await tester.pumpAndSettle();

        expect(
          tester.widget<SwitchListTile>(toggleFinder).value,
          isFalse,
        );
        expect(
          services.storage.getSetting('use_new_classifier'),
          equals('false'),
        );
        expect(services.pipeline.resolveUseNewClassifier(), isFalse);
        expect(find.textContaining('Legacy fallback active'), findsOneWidget);

        await tester.tap(toggleFinder);
        await tester.pumpAndSettle();

        expect(
          tester.widget<SwitchListTile>(toggleFinder).value,
          isTrue,
        );
        expect(
          services.storage.getSetting('use_new_classifier'),
          equals('true'),
        );
        expect(services.pipeline.resolveUseNewClassifier(), isTrue);
      },
    );

    testWidgets(
      'DiagnosticsScreen displays fallback banner when unhealthy and hides it for healthy Stockfish',
      (tester) async {
        final fallbackServices = AppServices.createDefault(
          seedDemoGame: false,
          autoDiscoverDesktopStockfish: false,
          refuseSilentFallback: false,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(fallbackServices),
            ],
            child: const MaterialApp(home: DiagnosticsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('diagnostics_unreliable_engine_banner')),
          findsOneWidget,
        );
        expect(
          find.textContaining('UNRELIABLE FALLBACK'),
          findsOneWidget,
        );

        final healthyEngine = _StubHealthyStockfishAdapter();
        final healthyExport = ExportService(
          storage: fallbackServices.storage,
          engine: healthyEngine,
          gateway: fallbackServices.gateway,
        );
        final healthyServices = AppServices(
          storage: fallbackServices.storage,
          gateway: fallbackServices.gateway,
          secureStore: fallbackServices.secureStore,
          engine: healthyEngine,
          openingBook: fallbackServices.openingBook,
          providerRegistry: fallbackServices.providerRegistry,
          pipeline: fallbackServices.pipeline,
          exportService: healthyExport,
          lichessSource: fallbackServices.lichessSource,
          chessComSource: fallbackServices.chessComSource,
          pgnSource: fallbackServices.pgnSource,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(healthyServices),
            ],
            child: const MaterialApp(home: DiagnosticsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('diagnostics_unreliable_engine_banner')),
          findsNothing,
        );
        expect(
          find.textContaining('Healthy (Native Stockfish)'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'GameReviewScreen shows warning banner for unanalysed fallback & unreliable summary, hides for Stockfish summary',
      (tester) async {
        final services = AppServices.createDefault(
          seedDemoGame: true,
          autoDiscoverDesktopStockfish: false,
          refuseSilentFallback: false,
        );
        final gameId = services.storage.listGames().first.id;

        Future<void> pumpReview(String phaseKey) async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appServicesProvider.overrideWithValue(services),
              ],
              child: MaterialApp(
                home: Scaffold(
                  body: GameReviewScreen(key: ValueKey(phaseKey)),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        // 1. Unanalysed game while live Stockfish is missing -> shows unavailable banner
        await pumpReview('unanalysed');

        final bannerFinder = find.byKey(const Key('unreliable_engine_banner'));
        await tester.scrollUntilVisible(
          bannerFinder,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(bannerFinder, findsOneWidget);
        expect(find.text('Stockfish engine unavailable'), findsOneWidget);

        // 2. Game analysed with 2-ply minimax fallback -> shows header chip & warning card
        await services.pipeline
            .analyseGame(gameId, explainMoments: false)
            .toList();
        await pumpReview('fallback_summary');

        expect(find.text('Fallback engine'), findsOneWidget);
        await tester.scrollUntilVisible(
          bannerFinder,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(bannerFinder, findsOneWidget);
        expect(
          find.text('Approximate review (fallback engine)'),
          findsOneWidget,
        );

        // 3. Game reviewed with real Stockfish -> hides header badge & warning banner
        final existing = services.storage.getGameSummary(gameId)!;
        services.storage.saveGameSummary(
          GameSummaryEntity(
            gameId: existing.gameId,
            accWhite: existing.accWhite,
            accBlack: existing.accBlack,
            acplWhite: existing.acplWhite,
            acplBlack: existing.acplBlack,
            phaseAccuracy: existing.phaseAccuracy,
            counts: existing.counts,
            presetId: existing.presetId,
            engineVersion: 'Stockfish 19 (nn-1a298aa575a0.nnue)',
          ),
        );

        await pumpReview('stockfish_summary');

        expect(find.text('Fallback engine'), findsNothing);
        await tester.drag(find.byType(ListView).first, const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(bannerFinder, findsNothing);
      },
    );
  });
}
