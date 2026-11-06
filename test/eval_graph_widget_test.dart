import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/domain/chess/chess_models.dart';
import 'package:movementor/src/presentation/features/review/eval_graph_widget.dart';

void main() {
  group('EvalGraphWidget tests', () {
    testWidgets('Renders placeholder when analyses is empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EvalGraphWidget(
              analyses: [],
              currentPly: 0,
              onSelectPly: null,
              onPlySelected: _noop,
            ),
          ),
        ),
      );

      expect(
        find.text('Run analysis to view the Win% evaluation curve.'),
        findsOneWidget,
      );
      expect(find.byType(LineChart), findsNothing);
    });

    testWidgets('Renders LineChart with single analysis item without crash', (tester) async {
      const singleAnalysis = MoveAnalysisEntity(
        gameId: 'g1',
        ply: 1,
        winBefore: 50.0,
        winAfter: 55.0,
        deltaW: 5.0,
        accuracy: 95.0,
        label: MoveClassification.best,
        isBook: false,
        isSacrifice: false,
        volatility: 1.0,
        phase: GamePhase.opening,
        presetId: 'lichess',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 70,
              child: EvalGraphWidget(
                analyses: [singleAnalysis],
                currentPly: 1,
                onSelectPly: _noop,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(LineChart), findsOneWidget);
    });

    testWidgets('Renders LineChart for multi-move analyses and supports tap & drag scrubbing',
        (tester) async {
      final triggeredPlies = <int>[];

      final analyses = List.generate(
        10,
        (i) => MoveAnalysisEntity(
          gameId: 'g1',
          ply: i + 1,
          winBefore: 50.0,
          winAfter: 50.0 + (i % 2 == 0 ? 5.0 : -5.0),
          deltaW: 2.0,
          accuracy: 90.0,
          label: MoveClassification.good,
          isBook: false,
          isSacrifice: false,
          volatility: 1.0,
          phase: GamePhase.middlegame,
          presetId: 'lichess',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 80,
              child: EvalGraphWidget(
                analyses: analyses,
                currentPly: 3,
                onSelectPly: (ply) {
                  triggeredPlies.add(ply);
                },
              ),
            ),
          ),
        ),
      );

      expect(find.byType(LineChart), findsOneWidget);

      // Verify LineChart configuration
      final lineChart = tester.widget<LineChart>(find.byType(LineChart));
      expect(lineChart.data.minY, 0.0);
      expect(lineChart.data.maxY, 100.0);
      expect(lineChart.data.extraLinesData.horizontalLines.any((l) => l.y == 50.0), isTrue);
      expect(lineChart.data.extraLinesData.verticalLines.any((l) => l.x == 3.0), isTrue);

      // Tap on chart
      await tester.tap(find.byType(EvalGraphWidget));
      await tester.pump();
      expect(triggeredPlies.isNotEmpty, isTrue);

      // Drag across chart horizontally
      triggeredPlies.clear();
      await tester.timedDrag(
        find.byType(EvalGraphWidget),
        const Offset(150, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pump();

      expect(triggeredPlies.isNotEmpty, isTrue);
      for (final p in triggeredPlies) {
        expect(p, inInclusiveRange(1, 10));
      }
    });

    testWidgets('Supports onPlySelected backward-compatible parameter', (tester) async {
      int? selected;
      final analyses = [
        const MoveAnalysisEntity(
          gameId: 'g1',
          ply: 1,
          winBefore: 50.0,
          winAfter: 55.0,
          deltaW: 5.0,
          accuracy: 95.0,
          label: MoveClassification.best,
          isBook: false,
          isSacrifice: false,
          volatility: 1.0,
          phase: GamePhase.opening,
          presetId: 'lichess',
        ),
        const MoveAnalysisEntity(
          gameId: 'g1',
          ply: 2,
          winBefore: 55.0,
          winAfter: 52.0,
          deltaW: 3.0,
          accuracy: 90.0,
          label: MoveClassification.good,
          isBook: false,
          isSacrifice: false,
          volatility: 1.0,
          phase: GamePhase.opening,
          presetId: 'lichess',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 60,
              child: EvalGraphWidget(
                analyses: analyses,
                currentPly: 1,
                onPlySelected: (p) => selected = p,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(EvalGraphWidget));
      await tester.pump();
      expect(selected, isNotNull);
    });

    testWidgets('Single analysis at non-1 ply renders within bounds and selects correctly',
        (tester) async {
      int? selected;
      const singleAnalysis = MoveAnalysisEntity(
        gameId: 'g1',
        ply: 5,
        winBefore: 50.0,
        winAfter: 55.0,
        deltaW: 5.0,
        accuracy: 95.0,
        label: MoveClassification.best,
        isBook: false,
        isSacrifice: false,
        volatility: 1.0,
        phase: GamePhase.opening,
        presetId: 'lichess',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 70,
              child: EvalGraphWidget(
                analyses: const [singleAnalysis],
                currentPly: 5,
                onSelectPly: (p) => selected = p,
              ),
            ),
          ),
        ),
      );

      final lineChart = tester.widget<LineChart>(find.byType(LineChart));
      expect(lineChart.data.minX <= 5.0 && lineChart.data.maxX >= 5.0, isTrue);
      await tester.tap(find.byType(EvalGraphWidget));
      await tester.pump();
      expect(selected, 5);
    });

    testWidgets('Vertical scroll in parent ListView is not intercepted by EvalGraphWidget',
        (tester) async {
      final scrollController = ScrollController();
      final triggeredPlies = <int>[];
      final analyses = List.generate(
        10,
        (i) => MoveAnalysisEntity(
          gameId: 'g1',
          ply: i + 1,
          winBefore: 50.0,
          winAfter: 50.0,
          deltaW: 0.0,
          accuracy: 90.0,
          label: MoveClassification.good,
          isBook: false,
          isSacrifice: false,
          volatility: 1.0,
          phase: GamePhase.middlegame,
          presetId: 'lichess',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 500,
              child: ListView(
                controller: scrollController,
                children: [
                  const SizedBox(height: 100),
                  EvalGraphWidget(
                    analyses: analyses,
                    currentPly: 1,
                    onSelectPly: (p) => triggeredPlies.add(p),
                  ),
                  const SizedBox(height: 1000),
                ],
              ),
            ),
          ),
        ),
      );

      expect(scrollController.offset, 0.0);
      // Drag vertically directly over EvalGraphWidget with slight realistic thumb angle
      await tester.timedDrag(
        find.byType(EvalGraphWidget),
        const Offset(10, -200),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();

      expect(scrollController.offset, greaterThan(50.0));
      expect(triggeredPlies.isEmpty, isTrue);
    });

    testWidgets('Analyses with offset range (plies 15 to 25) calculates correct bounds and plies on scrub',
        (tester) async {
      final triggered = <int>[];
      final analyses = List.generate(
        11,
        (i) => MoveAnalysisEntity(
          gameId: 'g1',
          ply: 15 + i,
          winBefore: 50.0,
          winAfter: 50.0 + (i % 2 == 0 ? 5.0 : -5.0),
          deltaW: 0.0,
          accuracy: 90.0,
          label: MoveClassification.good,
          isBook: false,
          isSacrifice: false,
          volatility: 1.0,
          phase: GamePhase.middlegame,
          presetId: 'lichess',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 70,
              child: EvalGraphWidget(
                analyses: analyses,
                currentPly: 20,
                onSelectPly: (p) => triggered.add(p),
              ),
            ),
          ),
        ),
      );

      final lineChart = tester.widget<LineChart>(find.byType(LineChart));
      expect(lineChart.data.minX, 15.0);
      expect(lineChart.data.maxX, 25.0);
      expect(lineChart.data.extraLinesData.verticalLines.any((l) => l.x == 20.0), isTrue);

      // Scrub horizontally
      await tester.timedDrag(
        find.byType(EvalGraphWidget),
        const Offset(100, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pump();

      expect(triggered.isNotEmpty, isTrue);
      for (final p in triggered) {
        expect(p, inInclusiveRange(15, 25));
      }
    });

    testWidgets('Current ply 0 (initial board) does not draw out-of-bounds marker',
        (tester) async {
      final analyses = [
        const MoveAnalysisEntity(
          gameId: 'g1',
          ply: 1,
          winBefore: 50.0,
          winAfter: 55.0,
          deltaW: 5.0,
          accuracy: 95.0,
          label: MoveClassification.best,
          isBook: false,
          isSacrifice: false,
          volatility: 1.0,
          phase: GamePhase.opening,
          presetId: 'lichess',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 70,
              child: EvalGraphWidget(
                analyses: analyses,
                currentPly: 0,
                onSelectPly: _noop,
              ),
            ),
          ),
        ),
      );

      final lineChart = tester.widget<LineChart>(find.byType(LineChart));
      expect(lineChart.data.extraLinesData.verticalLines.any((l) => l.x == 0.0), isFalse);
    });

    testWidgets('Renders properly in dark theme and narrow screen (240px)', (tester) async {
      final analyses = List.generate(
        5,
        (i) => MoveAnalysisEntity(
          gameId: 'g1',
          ply: i + 1,
          winBefore: 50.0,
          winAfter: 50.0,
          deltaW: 0.0,
          accuracy: 90.0,
          label: MoveClassification.good,
          isBook: false,
          isSacrifice: false,
          volatility: 1.0,
          phase: GamePhase.middlegame,
          presetId: 'lichess',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 70,
              child: EvalGraphWidget(
                analyses: analyses,
                currentPly: 3,
                onSelectPly: _noop,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(LineChart), findsOneWidget);
    });
  });
}

void _noop(int ply) {}
