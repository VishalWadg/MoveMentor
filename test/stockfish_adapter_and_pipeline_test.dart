import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chess/chess.dart' as ch;
import 'package:chess_review_core/chess_review_core.dart' as core;
import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/adapters/engine/stockfish_engine_adapter.dart';
import 'package:movementor/src/adapters/storage/opening_book_adapter.dart';
import 'package:movementor/src/adapters/storage/sqlite_storage_adapter.dart';
import 'package:movementor/src/application/analysis_pipeline_service.dart';
import 'package:movementor/src/application/app_state.dart';
import 'package:movementor/src/application/classifier_comparison_service.dart';
import 'package:movementor/src/domain/chess/pgn_parser.dart';
import 'package:movementor/src/domain/coach/coach_contracts.dart';
import 'package:movementor/src/ports/ports.dart';

class _RecordingStdin implements IOSink {
  final void Function(String line) onLine;
  final StringBuffer _buf = StringBuffer();
  @override
  Encoding encoding = utf8;

  _RecordingStdin(this.onLine);

  @override
  void add(List<int> data) {
    final chunk = encoding.decode(data);
    _buf.write(chunk);
    var content = _buf.toString();
    while (content.contains('\n')) {
      final idx = content.indexOf('\n');
      final line = content.substring(0, idx).replaceAll('\r', '').trim();
      content = content.substring(idx + 1);
      if (line.isNotEmpty) onLine(line);
    }
    _buf
      ..clear()
      ..write(content);
  }

  @override
  void write(Object? object) => add(encoding.encode(object.toString()));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future close() async {}

  @override
  Future get done => Future<void>.value();

  @override
  Future flush() async {}
}

class _FakeUciProcess implements Process {
  final StreamController<List<int>> stdoutCtrl = StreamController<List<int>>();
  final StreamController<List<int>> stderrCtrl = StreamController<List<int>>();
  final Completer<int> exitCompleter = Completer<int>();
  final List<String> receivedCommands = [];
  final void Function(String cmd, _FakeUciProcess proc) onCommand;
  late final _RecordingStdin _stdin;
  bool killed = false;

  _FakeUciProcess(this.onCommand) {
    _stdin = _RecordingStdin((line) {
      receivedCommands.add(line);
      onCommand(line, this);
    });
  }

  void emitLine(String line) {
    if (!stdoutCtrl.isClosed) {
      stdoutCtrl.add(utf8.encode('$line\n'));
    }
  }

  @override
  Future<int> get exitCode => exitCompleter.future;

  @override
  int get pid => 9999;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => stderrCtrl.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!exitCompleter.isCompleted) {
      exitCompleter.complete(0);
    }
    stdoutCtrl.close();
    stderrCtrl.close();
    return true;
  }
}

void main() {
  group('StockfishEngineAdapter UCI Protocol, Lifecycle, Error & Concurrency (Simulated Process)', () {
    test('Lifecycle, broadcast checkHealth reuse, MultiPV completeness & bound filtering', () async {
      late _FakeUciProcess fakeProc;
      final dummyBin = File('assets/openings/eco_openings.json').path;

      final adapter = StockfishEngineAdapter(
        customStockfishBinaryPath: dummyBin,
        refuseSilentFallback: true,
        processStarter: (_, __) async {
          var multiPv = 1;
          fakeProc = _FakeUciProcess((cmd, p) {
            if (cmd == 'uci') {
              p.emitLine('id name Stockfish FakeUCI');
              p.emitLine('option name EvalFile type string default fake.nnue');
              p.emitLine('uciok');
            } else if (cmd == 'isready') {
              p.emitLine('readyok');
            } else if (cmd.startsWith('setoption name MultiPV value ')) {
              multiPv = int.parse(cmd.split(' ').last);
            } else if (cmd.startsWith('go ')) {
              // Emit complete depth 7 for MultiPV=2, incomplete depth 8, and noisy upperbound depth 9
              p.emitLine('info depth 7 multipv 1 score cp 45 nodes 10000 pv e2e4 e7e5');
              if (multiPv >= 2) {
                p.emitLine('info depth 7 multipv 2 score cp 30 nodes 10000 pv d2d4 d7d5');
                p.emitLine('info depth 8 multipv 1 score cp 999 upperbound nodes 12000 pv h2h4');
              }
              p.emitLine('bestmove e2e4');
            }
          });
          return fakeProc;
        },
      );

      await adapter.init();
      expect(adapter.isHealthy, isTrue);
      expect(adapter.isFallbackEngine, isFalse);
      expect(adapter.engineVersion, equals('Stockfish FakeUCI (fake.nnue)'));

      // Repeated checkHealth calls must safely share broadcast stream without throwing.
      expect(await adapter.checkHealth(), isTrue);
      expect(await adapter.checkHealth(), isTrue);

      await adapter.newGame();
      expect(fakeProc.receivedCommands, contains('ucinewgame'));

      final res = await adapter.analyse(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        multiPv: 2,
        budget: const core.EngineBudget(nodes: 10000, threads: 1, hashMb: 16),
      );

      // Must select depth 7 (complete MultiPV 2) rather than partial/bound depth 8.
      expect(res.lines.length, equals(2));
      expect(res.lines[0].moveUci, equals('e2e4'));
      expect(res.lines[0].cp, equals(45));
      expect(res.lines[1].moveUci, equals('d2d4'));
      expect(res.lines[1].cp, equals(30));

      await adapter.dispose();
      expect(fakeProc.receivedCommands, contains('quit'));
      await expectLater(
        () => adapter.analyse(
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          budget: const core.EngineBudget(nodes: 10000),
        ),
        throwsStateError,
      );
    });

    test('Mid-search cancellation sends stop, cleans up UCI state, and recovers for next query', () async {
      final dummyBin = File('assets/openings/eco_openings.json').path;
      late _FakeUciProcess fakeProc;
      var goCount = 0;

      final adapter = StockfishEngineAdapter(
        customStockfishBinaryPath: dummyBin,
        refuseSilentFallback: true,
        processStarter: (_, __) async {
          fakeProc = _FakeUciProcess((cmd, p) {
            if (cmd == 'uci') {
              p.emitLine('id name Stockfish CancelTest');
              p.emitLine('uciok');
            } else if (cmd == 'isready') {
              p.emitLine('readyok');
            } else if (cmd.startsWith('go ')) {
              goCount++;
              final thisGo = goCount;
              if (thisGo == 1) {
                p.emitLine('info depth 5 multipv 1 score cp 20 nodes 500 pv e2e4');
                // Hold bestmove until stop arrives!
              } else {
                p.emitLine('info depth 10 multipv 1 score cp 55 nodes 10000 pv d2d4');
                p.emitLine('bestmove d2d4');
              }
            } else if (cmd == 'stop') {
              p.emitLine('bestmove e2e4');
            }
          });
          return fakeProc;
        },
      );

      await adapter.init();
      final cancel = CancelToken();

      final preCancelled = CancelToken()..cancel();
      await expectLater(
        () => adapter.analyse(
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          budget: const core.EngineBudget(nodes: 10000),
          cancel: preCancelled,
        ),
        throwsA(isA<EngineCancelledException>()),
      );

      final pendingSearch = adapter.analyse(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        budget: const core.EngineBudget(nodes: 5000000),
        cancel: cancel,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel.cancel();

      await expectLater(pendingSearch, throwsA(isA<EngineCancelledException>()));
      expect(fakeProc.receivedCommands, contains('stop'));

      // Next request immediately succeeds cleanly.
      final recovered = await adapter.analyse(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        budget: const core.EngineBudget(nodes: 10000),
      );
      expect(recovered.bestMoveUci, equals('d2d4'));
      expect(recovered.topLine?.cp, equals(55));

      await adapter.dispose();
    });

    test('Concurrent requests serialize FIFO without interleaving; crash & timeout fail cleanly', () async {
      final dummyBin = File('assets/openings/eco_openings.json').path;
      late _FakeUciProcess fakeProc;
      final trace = <String>[];
      var crashNext = false;
      var hangNext = false;

      final adapter = StockfishEngineAdapter(
        customStockfishBinaryPath: dummyBin,
        refuseSilentFallback: true,
        commandTimeout: const Duration(milliseconds: 120),
        searchTimeout: const Duration(milliseconds: 150),
        processStarter: (_, __) async {
          fakeProc = _FakeUciProcess((cmd, p) {
            trace.add(cmd);
            if (cmd == 'uci') {
              p.emitLine('id name Stockfish SerialTest');
              p.emitLine('uciok');
            } else if (cmd == 'isready') {
              p.emitLine('readyok');
            } else if (cmd.startsWith('go ')) {
              if (crashNext) {
                if (!p.exitCompleter.isCompleted) {
                  p.exitCompleter.complete(139);
                }
                return;
              }
              if (hangNext) {
                return; // Intentionally never emit bestmove -> trigger timeout
              }
              Future<void>.delayed(const Duration(milliseconds: 15), () {
                p.emitLine('info depth 6 multipv 1 score cp 12 nodes 5000 pv g1f3');
                p.emitLine('bestmove g1f3');
              });
            } else if (cmd == 'stop') {
              p.emitLine('bestmove g1f3');
            }
          });
          return fakeProc;
        },
      );

      await adapter.init();

      // Launch 3 concurrent requests simultaneously
      final results = await Future.wait([
        adapter.analyse(
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
          budget: const core.EngineBudget(nodes: 5000),
        ),
        adapter.analyse(
          'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
          budget: const core.EngineBudget(nodes: 5000),
        ),
        adapter.analyse(
          'rnbqkbnr/pppppppp/8/8/2P5/8/PP1PPPPP/RNBQKBNR b KQkq - 0 1',
          budget: const core.EngineBudget(nodes: 5000),
        ),
      ]);
      expect(results.length, equals(3));

      // Verify strict serialized ordering: every `position fen` is followed by `isready` -> `go` before the next `position fen`.
      final positionIndices = [
        for (var i = 0; i < trace.length; i++)
          if (trace[i].startsWith('position fen ')) i,
      ];
      expect(positionIndices.length, equals(3));
      for (var k = 0; k < positionIndices.length - 1; k++) {
        final slice = trace.sublist(positionIndices[k], positionIndices[k + 1]);
        expect(slice.any((c) => c == 'isready'), isTrue);
        expect(slice.any((c) => c.startsWith('go ')), isTrue);
      }

      // Timeout sends `stop` and rejects with TimeoutException
      hangNext = true;
      await expectLater(
        () => adapter.analyse(
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          budget: const core.EngineBudget(nodes: 5000),
        ),
        throwsA(isA<TimeoutException>()),
      );
      hangNext = false;

      // Process crash marks unhealthy and rejects cleanly without waiting for timeout
      crashNext = true;
      await expectLater(
        () => adapter.analyse(
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          budget: const core.EngineBudget(nodes: 5000),
        ),
        throwsStateError,
      );
      expect(adapter.isHealthy, isFalse);

      await adapter.dispose();
    });
  });

  final realStockfishPath = StockfishEngineAdapter.discoverDefaultStockfishPath();
  if (realStockfishPath != null) {
    group('Real Native Stockfish Integration Tests', () {
      test('Real UCI lifecycle, MultiPV 1/2/3, concurrent FIFO legality, cancellation & terminal skip', () async {
        final adapter = StockfishEngineAdapter(
          customStockfishBinaryPath: realStockfishPath,
          refuseSilentFallback: true,
        );
        await adapter.init();
        expect(adapter.isHealthy, isTrue);
        expect(adapter.isFallbackEngine, isFalse);
        expect(adapter.engineVersion, contains('Stockfish'));
        expect(await adapter.checkHealth(), isTrue);

        await adapter.newGame();

        // MultiPV 1 & MultiPV 3 on sharp middle-game position
        const tacticalFen =
            'r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2NP1N2/PPP2PPP/R1BQK2R b KQkq - 0 5';
        final mpv3 = await adapter.analyse(
          tacticalFen,
          multiPv: 3,
          budget: const core.EngineBudget(nodes: 25000, threads: 1, hashMb: 16),
        );
        expect(mpv3.lines.length, equals(3));
        expect(mpv3.lines.map((l) => l.multiPvRank), equals([1, 2, 3]));
        for (final l in mpv3.lines) {
          expect(l.winPercent, inInclusiveRange(0.0, 100.0));
          expect(l.pv, isNotEmpty);
        }

        // Terminal checkmate FEN returns empty without invoking search
        const mateFen = 'r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4';
        final terminalRes = await adapter.analyse(
          mateFen,
          multiPv: 2,
          budget: const core.EngineBudget(nodes: 10000),
        );
        expect(terminalRes.lines, isEmpty);
        expect(terminalRes.nodes, equals(0));

        // 4 concurrent requests on distinct FENs: every returned bestMove MUST be legal in its own FEN
        final testFens = [
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
          'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
          'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3',
        ];
        final concurrentResults = await Future.wait([
          for (final f in testFens)
            adapter.analyse(
              f,
              multiPv: 2,
              budget: const core.EngineBudget(nodes: 15000, threads: 1, hashMb: 16),
            ),
        ]);
        for (var i = 0; i < testFens.length; i++) {
          final board = ch.Chess.fromFEN(testFens[i]);
          final legalUcis = board
              .generate_moves()
              .map((m) => '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}')
              .toSet();
          expect(
            legalUcis.contains(concurrentResults[i].bestMoveUci),
            isTrue,
            reason: 'Returned illegal bestMove for concurrent FEN $i',
          );
        }

        // Real mid-search cancellation and immediate recovery
        final cancel = CancelToken();
        final slowSearch = adapter.analyse(
          tacticalFen,
          multiPv: 2,
          budget: const core.EngineBudget(nodes: 40000000, threads: 1, hashMb: 16),
          cancel: cancel,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        cancel.cancel();
        await expectLater(slowSearch, throwsA(isA<EngineCancelledException>()));

        // Engine stays healthy after real `stop` cancellation
        final postCancelEval = await adapter.evaluatePosition(
          testFens[0],
          const EnginePresetConfig(
            id: 'fixed_10k',
            displayName: 'Fixed 10k',
            threads: 1,
            hashMb: 16,
            moveTimeMs: 200,
            targetDepth: 12,
            fixedNodes: 10000,
          ),
          multiPv: 2,
        );
        expect(postCancelEval.isReliable, isTrue);
        expect(postCancelEval.pvUci, isNotEmpty);
        expect(postCancelEval.multipv.length, equals(2));

        await adapter.dispose();
        expect(adapter.isDisposed, isTrue);
      });
    });
  }

  group('OpeningBookAdapter, useNewClassifier Flag & Comparison Service Contracts', () {
    test('OpeningBookAdapter handles EPD transpositions and unreachable en-passant normalization', () {
      final book = OpeningBookAdapter.fromFileSync('assets/openings/eco_openings.json');
      expect(book.entryCount, greaterThanOrEqualTo(3000));

      // Transposition to French Defense: 1. e4 e6 2. d4 d5 == 1. d4 e6 2. e4 d5
      final g1 = ch.Chess();
      for (final san in ['e4', 'e6', 'd4', 'd5']) {
        g1.move(san);
      }
      final g2 = ch.Chess();
      for (final san in ['d4', 'e6', 'e4', 'd5']) {
        g2.move(san);
      }

      final e1 = book.lookupByFen(g1.fen);
      final e2 = book.lookupByFen(g2.fen);
      expect(e1, isNotNull);
      expect(e2, isNotNull);
      expect(e1!.eco, equals(e2!.eco));
      expect(e1.epd, equals(e2.epd));

      // Stripped unreachable en-passant square after 1. e4 still resolves to e4 opening
      final strippedE4 = book.lookupByEpd('rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -');
      expect(strippedE4, isNotNull);
    });

    test('useNewClassifier defaults true and switches cleanly between chess_review_core and legacy fallback pipelines', () async {
      // Uses fake Stockfish UCI process so test runs fast & deterministically offline everywhere
      final dummyBin = File('assets/openings/eco_openings.json').path;
      final services = AppServices.createDefault(
        seedDemoGame: false,
        stockfishBinaryPath: dummyBin,
      );
      expect(services.pipeline.defaultUseNewClassifier, isTrue);
      expect(services.pipeline.resolveUseNewClassifier(), isTrue);
      expect(AppUiNotifier(services).state.useNewClassifier, isTrue);

      final uiNotifier = AppUiNotifier(services);
      uiNotifier.setUseNewClassifier(false);
      expect(uiNotifier.state.useNewClassifier, isFalse);
      expect(services.storage.getSetting('use_new_classifier'), equals('false'));
      expect(services.pipeline.resolveUseNewClassifier(), isFalse);
      expect(AppUiNotifier(services).state.useNewClassifier, isFalse);

      uiNotifier.setUseNewClassifier(true);
      expect(uiNotifier.state.useNewClassifier, isTrue);
      expect(services.storage.getSetting('use_new_classifier'), equals('true'));
      expect(services.pipeline.resolveUseNewClassifier(), isTrue);

      // Run a full game through AnalysisPipelineService defaulting to useNewClassifier: true on deterministic UCI fake
      var lastFen = '';
      var multiPv = 1;
      final fakeAdapter = StockfishEngineAdapter(
        customStockfishBinaryPath: dummyBin,
        refuseSilentFallback: true,
        processStarter: (_, __) async => _FakeUciProcess((cmd, p) {
          if (cmd == 'uci') {
            p.emitLine('id name Stockfish PipelineFake');
            p.emitLine('uciok');
          } else if (cmd == 'isready') {
            p.emitLine('readyok');
          } else if (cmd.startsWith('position fen ')) {
            lastFen = cmd.substring('position fen '.length).trim();
          } else if (cmd.startsWith('setoption name MultiPV value ')) {
            multiPv = int.parse(cmd.split(' ').last);
          } else if (cmd.startsWith('go ')) {
            // Position at fullmove 5 (' 5') onward triggers non-book tactical swing
            final cp = (lastFen.endsWith(' 5') || lastFen.endsWith(' 6')) &&
                    lastFen.contains(' b ')
                ? 320
                : 25;
            p.emitLine('info depth 8 multipv 1 score cp $cp nodes 5000 pv e2e4 e7e5');
            if (multiPv >= 2) {
              p.emitLine('info depth 8 multipv 2 score cp ${cp - 40} nodes 5000 pv d2d4 d7d5');
            }
            p.emitLine('bestmove e2e4');
          }
        }),
      );
      await fakeAdapter.init();

      final storage = StorageRepository();
      final book = OpeningBookAdapter.fromStorage(storage);
      final pipeline = AnalysisPipelineService(
        storage: storage,
        engine: fakeAdapter,
        providerRegistry: services.providerRegistry,
        openingBook: book,
      );
      expect(pipeline.defaultUseNewClassifier, isTrue);

      const samplePgn = '''
[Event "Toggle Test"]
[White "A"]
[Black "B"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. b4 Bxb4 5. a4 Qf6 6. h4 Qg6 *
''';
      final parsed = PgnParser.parseMultiGamePgn(samplePgn, source: 'pgn').games.single;
      storage.upsertParsedGame(parsed);
      final gameId = parsed.game.id;

      // Default (true, no setting key set) -> runs chess_review_core + Aggregates + Stages 4-6 cleanly
      final coreStates = await pipeline
          .analyseGame(gameId, explainMoments: true)
          .toList();
      expect(coreStates.last.stage, equals('done'));
      final summary = storage.getGameSummary(gameId);
      expect(summary, isNotNull);
      expect(summary!.engineVersion, contains('Stockfish PipelineFake'));
      expect(storage.getCriticalMoments(gameId), isNotEmpty);
      expect(storage.getMoveAnalyses(gameId).length, equals(12));

      // Flag false -> explicit legacy classifier fallback still works cleanly
      storage.setSetting('use_new_classifier', 'false');
      expect(pipeline.resolveUseNewClassifier(), isFalse);
      final legacyStates = await pipeline
          .analyseGame(gameId, explainMoments: false)
          .toList();
      expect(legacyStates.last.stage, equals('done'));
      expect(storage.getMoveAnalyses(gameId).length, equals(12));

      await fakeAdapter.dispose();
    });

    test('AppServices.createDefault hydrates ECO opening book before seeding demo game', () {
      final services = AppServices.createDefault(
        seedDemoGame: true,
        autoDiscoverDesktopStockfish: false,
      );
      expect(services.openingBook.entryCount, greaterThanOrEqualTo(3000));
      expect(services.pipeline.defaultUseNewClassifier, isTrue);

      final seededGames = services.storage.listGames();
      expect(seededGames, isNotEmpty);

      // StorageRepository was hydrated prior to game upserts so headerless PGNs enrich immediately
      const headerlessItalian = '''
[Event "ECO Check"]
[White "W"]
[Black "B"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 *
''';
      final parsed =
          PgnParser.parseMultiGamePgn(headerlessItalian, source: 'pgn').games.single;
      services.storage.upsertParsedGame(parsed);
      final saved = services.storage.getGame(parsed.game.id);
      expect(saved, isNotNull);
      expect(saved!.eco, equals('C50'));
      expect(saved.openingName, isNotNull);
      expect(saved.openingName, isNotEmpty);
    });

    test('AppServices.ensureOpeningsLoaded hydrates openingBook asynchronously when starting empty', () async {
      final base = AppServices.createDefault(
        seedDemoGame: false,
        autoDiscoverDesktopStockfish: false,
      );
      final emptyBook = OpeningBookAdapter.fromEntries(const []);
      expect(emptyBook.entryCount, equals(0));

      final services = AppServices(
        storage: StorageRepository(),
        gateway: base.gateway,
        secureStore: base.secureStore,
        engine: base.engine,
        openingBook: emptyBook,
        providerRegistry: base.providerRegistry,
        pipeline: base.pipeline,
        exportService: base.exportService,
        lichessSource: base.lichessSource,
        chessComSource: base.chessComSource,
        pgnSource: base.pgnSource,
      );

      var loaderCalls = 0;
      await services.ensureOpeningsLoaded((path) async {
        loaderCalls++;
        expect(path, equals('assets/openings/eco_openings.json'));
        return '[{"eco":"C50","name":"Italian Game","epd":"r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq -","uci":"e2e4 e7e5 g1f3 b8c6 f1c4"}]';
      });

      expect(loaderCalls, equals(1));
      expect(services.openingBook.entryCount, equals(1));
      final entry = services.openingBook.lookupByEpd(
        'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq -',
      );
      expect(entry, isNotNull);
      expect(entry!.eco, equals('C50'));
    });

    test('AnalysisPipelineService throws StateError under refuseSilentFallback: true when no Stockfish binary exists', () async {
      final services = AppServices.createDefault(
        seedDemoGame: false,
        autoDiscoverDesktopStockfish: false,
        refuseSilentFallback: true,
      );
      const nonBookPgn = '''
[Event "Strict Fallback Guard"]
[White "W"]
[Black "B"]
[Result "*"]

1. a4 a5 2. h4 h5 *
''';
      final parsed =
          PgnParser.parseMultiGamePgn(nonBookPgn, source: 'pgn').games.single;
      services.storage.upsertParsedGame(parsed);

      await expectLater(
        services.pipeline
            .analyseGame(parsed.game.id, explainMoments: false)
            .toList(),
        throwsStateError,
      );
    });

    test('GameReviewRunner.runNewCore marks unreliable fallback evals and engineVersion when refuseSilentFallback is false', () async {
      final services = AppServices.createDefault(
        seedDemoGame: false,
        autoDiscoverDesktopStockfish: false,
        refuseSilentFallback: false,
      );
      const nonBookPgn = '''
[Event "Permissive Unreliable Marker"]
[White "W"]
[Black "B"]
[Result "*"]

1. a4 a5 2. h4 h5 *
''';
      final parsed =
          PgnParser.parseMultiGamePgn(nonBookPgn, source: 'pgn').games.single;
      services.storage.upsertParsedGame(parsed);

      final states = await services.pipeline
          .analyseGame(parsed.game.id, explainMoments: false)
          .toList();
      expect(states.last.stage, equals('done'));

      final evals = services.storage.allEngineEvals;
      expect(evals, isNotEmpty);
      expect(evals.every((e) => !e.isReliable), isTrue);

      final summary = services.storage.getGameSummary(parsed.game.id);
      expect(summary, isNotNull);
      expect(summary!.engineVersion, contains('UNRELIABLE-FALLBACK'));
    });

    test('ClassifierComparisonService enforces minimum 500k node search budget', () async {
      final dummyBin = File('assets/openings/eco_openings.json').path;
      final fakeAdapter = StockfishEngineAdapter(
        customStockfishBinaryPath: dummyBin,
        refuseSilentFallback: true,
        processStarter: (_, __) async => _FakeUciProcess((cmd, p) {
          if (cmd == 'uci') p.emitLine('uciok');
          if (cmd == 'isready') p.emitLine('readyok');
        }),
      );
      await fakeAdapter.init();
      final cmp = ClassifierComparisonService(
        engine: fakeAdapter,
        openingBookEntries: const [],
      );
      await expectLater(
        () => cmp.compareGames(
          const [],
          budget: const core.EngineBudget(nodes: 10000),
        ),
        throwsArgumentError,
      );
      await fakeAdapter.dispose();
    });
  });
}
