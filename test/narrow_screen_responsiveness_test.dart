import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/application/app_state.dart';
import 'package:movementor/src/presentation/screens/movementor_screens.dart';

void main() {
  group('Narrow screen responsiveness tests (320px - 360px)', () {
    const testWidths = [360.0, 320.0];

    testWidgets('GameReviewScreen renders without overflow on 360px and 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);
      final games = services.storage.listGames();
      expect(games, isNotEmpty);
      final gameId = games.first.id;

      await services.pipeline.analyseGame(gameId).toList();

      for (final width in testWidths) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: width,
                  height: 700,
                  child: const GameReviewScreen(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'Failed at width: $width');

        // Tap Next move to navigate to ply 1 (analysed move)
        final nextBtn = find.byTooltip('Next move');
        expect(nextBtn, findsOneWidget);
        await tester.tap(nextBtn);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Failed at ply 1, width: $width');

        // Scroll down to make critical moments and coach commentary visible
        await tester.drag(find.byType(GameReviewScreen), const Offset(0, -260));
        await tester.pumpAndSettle();

        // Tap a critical moment chip to view coach explanation
        final momentFinder = find.byType(ActionChip);
        if (momentFinder.evaluate().isNotEmpty) {
          await tester.tap(momentFinder.first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'Failed at critical moment, width: $width');
        }
      }
    });

    testWidgets('GameReviewScreen and Settings with large text scaler 1.4x render without overflow', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);
      final games = services.storage.listGames();
      await services.pipeline.analyseGame(games.first.id).toList();

      for (final width in testWidths) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: width,
                  height: 700,
                  child: const GameReviewScreen(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Failed GameReviewScreen with 1.4x text scaler at width: $width');

        final nextBtn = find.byTooltip('Next move');
        await tester.tap(nextBtn);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Failed GameReviewScreen ply 1 with 1.4x text scaler at width: $width');

        // Test SettingsHubScreen with 1.4x text scaler
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: width,
                  height: 700,
                  child: const SettingsHubScreen(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Failed SettingsHubScreen with 1.4x text scaler at width: $width');
      }
    });

    testWidgets('SettingsHubScreen renders without overflow on 360px and 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);

      for (final width in testWidths) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: width,
                  height: 700,
                  child: const SettingsHubScreen(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'Failed at width: $width');
      }
    });

    testWidgets('ModelAndStorageScreen renders without overflow on 360px and 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);

      for (final width in testWidths) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: SizedBox(
                width: width,
                height: 700,
                child: const ModelAndStorageScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'Failed at width: $width');

        // Scroll to the bottom to verify all action buttons and storage tiles render without overflow
        await tester.drag(find.byType(ModelAndStorageScreen), const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Failed at bottom of ModelAndStorageScreen at width: $width');
      }
    });

    testWidgets('ProviderEditorScreen renders without overflow on 360px and 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);

      for (final width in testWidths) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: SizedBox(
                width: width,
                height: 700,
                child: const ProviderEditorScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'Failed at width: $width');

        final testBtn = find.text('Test connection');
        await tester.tap(testBtn);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Failed after Test connection at width: $width');
      }
    });

    testWidgets('ImportHubScreen renders without overflow on 360px and 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);

      for (final width in testWidths) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: SizedBox(
                width: width,
                height: 700,
                child: const ImportHubScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'Failed at width: $width');
      }
    });

    testWidgets('GameLibraryScreen renders without overflow on 360px and 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);
      final games = services.storage.listGames();
      await services.pipeline.analyseGame(games.first.id).toList();

      for (final width in testWidths) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: width,
                  height: 700,
                  child: const GameLibraryScreen(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'Failed at width: $width');
      }
    });

    testWidgets('WeaknessDashboardScreen renders without overflow on 360px and 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);

      for (final width in testWidths) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: width,
                  height: 700,
                  child: const WeaknessDashboardScreen(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'Failed at width: $width');
      }
    });

    testWidgets('OnboardingScreen renders without overflow on 360px and 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);

      for (final width in testWidths) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: SizedBox(
                width: width,
                height: 700,
                child: const OnboardingScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'Failed at width: $width');
      }
    });

    testWidgets('GameReviewScreen without analysis renders without overflow on 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);
      tester.view.physicalSize = const Size(320.0, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appServicesProvider.overrideWithValue(services),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320.0,
                height: 700,
                child: GameReviewScreen(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Select a move or run analysis to see coaching.'), findsOneWidget);

      // Tap Next move button
      final nextBtn = find.byTooltip('Next move');
      expect(nextBtn, findsOneWidget);
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('ExportDataScreen, DiagnosticsScreen, LicencesScreen render without overflow on 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);
      tester.view.physicalSize = const Size(320.0, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      for (final screen in const [ExportDataScreen(), DiagnosticsScreen(), LicencesAndPrivacyScreen()]) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appServicesProvider.overrideWithValue(services),
            ],
            child: MaterialApp(
              home: SizedBox(
                width: 320.0,
                height: 700,
                child: screen,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('Full MoveMentorAppShell renders without overflow across all 4 tabs on 320px', (tester) async {
      final services = AppServices.createDefault(seedDemoGame: true);
      tester.view.physicalSize = const Size(320.0, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Complete onboarding so AppShell shows the main tabs
      services.storage.setSetting('onboarding_done', 'true');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appServicesProvider.overrideWithValue(services),
          ],
          child: const MaterialApp(
            home: SizedBox(
              width: 320.0,
              height: 700,
              child: MoveMentorAppShell(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Switch to Review tab (index 1)
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Switch to Dashboard tab (index 2)
      await tester.tap(find.text('Dashboard'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Switch to Settings tab (index 3)
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}

