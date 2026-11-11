import 'dart:convert';
import 'dart:io';
import 'package:chess_review_core/chess_review_core.dart' as core;
import 'package:movementor/src/adapters/engine/stockfish_engine_adapter.dart';
import 'package:movementor/src/application/classifier_comparison_service.dart';

const List<ComparisonGameInput> _benchmarkGames = [
  ComparisonGameInput(
    id: 'g1_italian',
    title: '1. Italian Game Tactical Mate (39 plies, k=3)',
    pgn: '''
[Event "Club Rapid Championship"]
[Site "Offline OTB"]
[Date "2026.11.01"]
[White "PlayerOne"]
[Black "ClubOpponent"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6 5. d4 exd4 6. cxd4 Bb4+ 7. Nc3 Nxe4 8. O-O Nxc3 9. bxc3 Bxc3 10. Qb3 Bxa1 11. Bxf7+ Kf8 12. Bg5 Ne7 13. Ne5 Bxd4 14. Bg6 d5 15. Qf3+ Bf5 16. Bxf5 Bxe5 17. Be6+ Bf6 18. Bxf6 gxf6 19. Qxf6+ Ke8 20. Qf7# 1-0
''',
  ),
  ComparisonGameInput(
    id: 'g2_petrov_draw',
    title: '2. Quiet Petrov Endgame Draw (62 plies, k=6)',
    pgn: '''
[Event "Endgame Benchmark"]
[White "PositionalA"]
[Black "PositionalB"]
[Result "1/2-1/2"]

1. e4 e5 2. Nf3 Nf6 3. Nxe5 d6 4. Nf3 Nxe4 5. Qe2 Qe7 6. d3 Nf6 7. Bg5 Qxe2+ 8. Bxe2 Be7 9. Nc3 c6 10. O-O-O Na6 11. Rhe1 Nc7 12. Bf1 Ne6 13. Bxf6 Bxf6 14. Ne4 Be7 15. d4 d5 16. Ned2 f6 17. g3 Kf7 18. Bh3 Ng5 19. Nxg5+ fxg5 20. Bxc8 Raxc8 21. Nf3 Bf6 22. Ne5+ Bxe5 23. Rxe5 h6 24. Rde1 Rce8 25. Kd2 Rxe5 26. Rxe5 Re8 27. Re3 Rb8 28. Rf3+ Kg6 29. Re3 Kf7 30. Rf3+ Kg6 31. Re3 Kf7 1/2-1/2
''',
  ),
  ComparisonGameInput(
    id: 'g3_french_greek_gift',
    title: '3. French Greek Gift Sac & Miss (36 plies, k=3)',
    pgn: '''
[Event "Tactical Benchmark"]
[White "Attacker"]
[Black "Defender"]
[Result "*"]

1. e4 e6 2. d4 d5 3. Nc3 Nf6 4. Bg5 Be7 5. e5 Nfd7 6. Bxe7 Qxe7 7. f4 O-O 8. Nf3 c5 9. dxc5 Nc6 10. Bd3 a6 11. Bxh7+ Kxh7 12. Ng5+ Kg6 13. Qd3+ f5 14. Qg3 Ndxe5 15. h4 Nc4 16. Nxe6+ Kf7 17. O-O-O Bxe6 18. Rhe1 Qxc5 *
''',
  ),
  ComparisonGameInput(
    id: 'g4_kasparov_topalov',
    title: '4. Kasparov-Topalov 1999 (87 plies, k=8)',
    pgn: '''
[Event "Hoogovens"]
[White "Kasparov, Garry"]
[Black "Topalov, Veselin"]
[Result "1-0"]

1. e4 d6 2. d4 Nf6 3. Nc3 g6 4. Be3 Bg7 5. Qd2 c6 6. f3 b5 7. Nge2 Nbd7 8. Bh6 Bxh6 9. Qxh6 Bb7 10. a3 e5 11. O-O-O Qe7 12. Kb1 a6 13. Nc1 O-O-O 14. Nb3 exd4 15. Rxd4 c5 16. Rd1 Nb6 17. g3 Kb8 18. Na5 Ba8 19. Bh3 d5 20. Qf4+ Ka7 21. Rhe1 d4 22. Nd5 Nbxd5 23. exd5 Qd6 24. Rxd4 cxd4 25. Re7+ Kb6 26. Qxd4+ Kxa5 27. b4+ Ka4 28. Qc3 Qxd5 29. Ra7 Bb7 30. Rxb7 Qc4 31. Qxf6 Kxa3 32. Qxa6+ Kxb4 33. c3+ Kxc3 34. Qa1+ Kd2 35. Qb2+ Kd1 36. Bf1 Rd2 37. Rd7 Rxd7 38. Bxc4 bxc4 39. Qxh8 Rd3 40. Qa8 c3 41. Qa4+ Ke1 42. f4 f5 43. Kc1 Rd2 44. Qa7 1-0
''',
  ),
  ComparisonGameInput(
    id: 'g5_byrne_fischer',
    title: '5. Byrne-Fischer 1956 (82 plies, k=8)',
    pgn: '''
[Event "Rosenwald Memorial"]
[White "Byrne, Donald"]
[Black "Fischer, Robert James"]
[Result "0-1"]

1. Nf3 Nf6 2. c4 g6 3. Nc3 Bg7 4. d4 O-O 5. Bf4 d5 6. Qb3 dxc4 7. Qxc4 c6 8. e4 Nbd7 9. Rd1 Nb6 10. Qc5 Bg4 11. Bg5 Na4 12. Qa3 Nxc3 13. bxc3 Nxe4 14. Bxe7 Qb6 15. Bc4 Nxc3 16. Bc5 Rfe8+ 17. Kf1 Be6 18. Bxb6 Bxc4+ 19. Kg1 Ne2+ 20. Kf1 Nxd4+ 21. Kg1 Ne2+ 22. Kf1 Nc3+ 23. Kg1 axb6 24. Qb4 Ra4 25. Qxb6 Nxd1 26. h3 Rxa2 27. Kh2 Nxf2 28. Re1 Rxe1 29. Qd8+ Bf8 30. Nxe1 Bd5 31. Nf3 Ne4 32. Qb8 b5 33. h4 h5 34. Ne5 Kg7 35. Kg1 Bc5+ 36. Kf1 Ng3+ 37. Ke1 Bb4+ 38. Kd1 Bb3+ 39. Kc1 Ne2+ 40. Kb1 Nc3+ 41. Kc1 Rc2# 0-1
''',
  ),
  ComparisonGameInput(
    id: 'g6_morphy_opera',
    title: '6. Morphy Opera Game 1858 (33 plies, k=3)',
    pgn: '''
[Event "Paris Opera"]
[White "Morphy, Paul"]
[Black "Duke Karl / Count Isouard"]
[Result "1-0"]

1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7 14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0
''',
  ),
];

Future<void> main(List<String> args) async {
  final nodes = args.isNotEmpty ? int.tryParse(args.first) ?? 500000 : 500000;
  final outPath = args.length >= 2 ? args[1] : null;

  final binPath = StockfishEngineAdapter.discoverDefaultStockfishPath();
  if (binPath == null) {
    stderr.writeln(
      'Error: Native Stockfish binary not found. Set STOCKFISH_PATH environment variable.',
    );
    exit(2);
  }

  final openingsFile = File('assets/openings/eco_openings.json');
  if (!openingsFile.existsSync()) {
    stderr.writeln('Error: assets/openings/eco_openings.json not found.');
    exit(2);
  }
  final bookEntries =
      (jsonDecode(openingsFile.readAsStringSync()) as List<dynamic>)
          .cast<Map<String, dynamic>>();

  stdout.writeln('Initializing Stockfish at: $binPath');
  final engine = StockfishEngineAdapter(
    customStockfishBinaryPath: binPath,
    refuseSilentFallback: true,
  );
  await engine.init();

  if (!await engine.checkHealth()) {
    stderr.writeln('Error: Stockfish UCI handshake failed.');
    await engine.dispose();
    exit(2);
  }

  stdout.writeln(
    'Running side-by-side comparison across ${_benchmarkGames.length} games '
    'with ${engine.engineVersion} at nodes=$nodes, threads=1, hash=16...',
  );

  final sw = Stopwatch()..start();
  try {
    final service = ClassifierComparisonService(
      engine: engine,
      openingBookEntries: bookEntries,
    );
    final report = await service.compareGames(
      _benchmarkGames,
      budget: core.EngineBudget(nodes: nodes, threads: 1, hashMb: 16),
    );
    sw.stop();

    final md = StringBuffer();
    md.writeln(report.toMarkdownReport());
    md.writeln('## Discrepancy Category Breakdown');
    md.writeln('| Category | Count |');
    md.writeln('|---|---:|');
    final sortedCats = report.discrepancyCategoryCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final c in sortedCats) {
      md.writeln('| ${c.key} | ${c.value} |');
    }
    md.writeln();
    md.writeln('## Sample Disagreements (First 25)');
    md.writeln('| Game | Ply | Side | Move | Old | New | dW | Category |');
    md.writeln('|---|---:|---|---|---|---|---:|---|');
    for (final d in report.sampleDisagreements.take(25)) {
      md.writeln(
        '| ${d.gameTitle} | ${d.ply} | ${d.side} | ${d.moveSan} | '
        '${d.oldLabel.label} | ${d.newLabel.label} | '
        '${d.deltaW.toStringAsFixed(1)} | ${d.reasonCategory} |',
      );
    }
    md.writeln();
    md.writeln('_Completed in ${(sw.elapsedMilliseconds / 1000.0).toStringAsFixed(1)}s._');

    final outputText = md.toString();
    stdout.writeln(outputText);
    if (outPath != null) {
      File(outPath).writeAsStringSync(outputText);
      stdout.writeln('Saved comparison report to: $outPath');
    }
  } finally {
    await engine.dispose();
  }
}
