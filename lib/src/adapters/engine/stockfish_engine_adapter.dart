import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:chess/chess.dart' as ch;
import 'package:chess_review_core/chess_review_core.dart' as core;
import '../../domain/chess/chess_models.dart';
import '../../domain/chess/see_evaluator.dart';
import '../../domain/coach/coach_contracts.dart';
import '../../ports/ports.dart';
import 'ffi_uci_transport.dart';
import 'uci_transport.dart';

export 'uci_transport.dart' show ProcessStarter, UciEngineTransport;

/// Exception thrown when a queued or active engine search is cancelled.
class EngineCancelledException implements Exception {
  final String message;
  const EngineCancelledException([this.message = 'Engine search cancelled']);

  @override
  String toString() => 'EngineCancelledException: $message';
}

/// Native UCI Stockfish Engine Adapter implementing both the legacy app [EngineService]
/// port and the pure-Dart [core.EngineServicePort].
///
/// Behavior:
/// - When configured with a valid native Stockfish executable, performs a persistent
///   UCI handshake (`uci` / `uciok`), captures `id name` + `EvalFile`, serializes
///   requests over a FIFO queue to guarantee thread-safe stdin/stdout ordering,
///   supports MultiPV, fixed-node deterministic search (`go nodes`), `ucinewgame`,
///   and clean mid-search cancellation (`stop` -> `bestmove`).
/// - When no binary is found, marks [_isHealthy] false (`isFallbackEngine == true`).
///   Calls via [core.EngineServicePort.analyse] refuse unhealthy fallback; legacy
///   [evaluatePosition] refuses when [refuseSilentFallback] is true and otherwise
///   returns `isReliable: false` deterministic 2-ply minimax for offline UI tests.
class StockfishEngineAdapter implements EngineService, core.EngineServicePort {
  final String? customStockfishBinaryPath;
  final bool refuseSilentFallback;
  final Duration commandTimeout;
  final Duration searchTimeout;
  final ProcessStarter _processStarter;
  final FfiTransportStarter? _ffiTransportStarter;
  final Future<String?> Function()? _androidEvalFileResolver;

  UciEngineTransport? _transport;
  Future<void>? _initInFlight;

  bool _thermalThrottled = false;
  bool _isHealthy = false;
  bool _disposed = false;
  String? _idName;
  String? _evalFile;

  int? _lastThreads;
  int? _lastHashMb;
  int? _lastMultiPv;

  Future<void> _serialQueue = Future<void>.value();
  bool _hasActiveSearch = false;
  bool _cancelRequested = false;
  void Function(String reason)? _abortPendingWaiter;

  StockfishEngineAdapter({
    this.customStockfishBinaryPath,
    this.refuseSilentFallback = false,
    this.commandTimeout = const Duration(seconds: 5),
    this.searchTimeout = const Duration(seconds: 45),
    ProcessStarter? processStarter,
    FfiTransportStarter? ffiTransportStarter,
    Future<String?> Function()? androidEvalFileResolver,
  })  : _processStarter = processStarter ?? Process.start,
        _ffiTransportStarter = ffiTransportStarter,
        _androidEvalFileResolver = androidEvalFileResolver;

  /// Whether a native binary or Android FFI transport can be attempted on this host.
  bool get canAttemptNativeInit {
    final bin = customStockfishBinaryPath;
    if (bin != null && bin.isNotEmpty) return true;
    if (_ffiTransportStarter != null) return true;
    if (Platform.isAndroid && _androidEvalFileResolver != null) return true;
    return false;
  }

  /// Searches environment (`STOCKFISH_PATH`) and standard local install paths
  /// for a native Stockfish executable on desktop platforms.
  static String? discoverDefaultStockfishPath() {
    final envPath = Platform.environment['STOCKFISH_PATH'];
    if (envPath != null && envPath.isNotEmpty && File(envPath).existsSync()) {
      return envPath;
    }

    final candidates = <String>[
      if (Platform.isWindows) ...[
        if (Platform.environment['LOCALAPPDATA'] != null)
          '${Platform.environment['LOCALAPPDATA']}\\Microsoft\\WinGet\\Packages\\Stockfish.Stockfish_Microsoft.Winget.Source_8wekyb3d8bbwe\\stockfish\\stockfish-windows-x86-64-universal.exe',
        if (Platform.environment['LOCALAPPDATA'] != null)
          '${Platform.environment['LOCALAPPDATA']}\\Microsoft\\WinGet\\Links\\stockfish.exe',
      ] else ...[
        '/usr/games/stockfish',
        '/usr/local/bin/stockfish',
        '/usr/bin/stockfish',
        '/opt/homebrew/bin/stockfish',
      ],
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  @override
  String get engineVersion {
    if (!_isHealthy) {
      return 'Minimax-2Ply (UNRELIABLE-FALLBACK)';
    }
    final name = _idName ?? 'Stockfish-UCI';
    if (_evalFile != null && _evalFile!.isNotEmpty && _evalFile != '<empty>') {
      return '$name ($_evalFile)';
    }
    return name;
  }

  @override
  bool get isFallbackEngine => !_isHealthy;

  bool get isHealthy => _isHealthy;

  bool get isDisposed => _disposed;

  @override
  bool get isThermalThrottled => _thermalThrottled;

  @override
  void setThermalThrottle(bool throttled) {
    _thermalThrottled = throttled;
  }

  @override
  Future<void> init() {
    if (_disposed) {
      throw StateError('StockfishEngineAdapter has already been disposed');
    }
    if (_transport != null && _isHealthy) {
      return Future<void>.value();
    }
    if (_initInFlight != null) {
      return _initInFlight!;
    }
    final future = _doInit();
    _initInFlight = future;
    return future.whenComplete(() {
      if (identical(_initInFlight, future)) {
        _initInFlight = null;
      }
    });
  }

  Future<void> _doInit() async {
    try {
      String? resolvedEvalFile;
      final UciEngineTransport transport;

      final binPath = customStockfishBinaryPath;
      if (binPath != null && binPath.isNotEmpty) {
        if (!File(binPath).existsSync()) {
          _isHealthy = false;
          return;
        }
        final proc = await _processStarter(binPath, const []);
        transport = ProcessUciTransport(proc);
      } else if (_ffiTransportStarter != null || Platform.isAndroid) {
        final resolver = _androidEvalFileResolver;
        if (resolver == null) {
          _isHealthy = false;
          return;
        }
        resolvedEvalFile = await resolver();
        if (resolvedEvalFile == null ||
            resolvedEvalFile.isEmpty ||
            !File(resolvedEvalFile).existsSync()) {
          _isHealthy = false;
          return;
        }
        final evalDir = File(resolvedEvalFile).parent.path;
        final ffiStarter = _ffiTransportStarter;
        transport = ffiStarter != null
            ? await ffiStarter(evalDir: evalDir)
            : await FfiUciTransport.start(evalDir: evalDir);
      } else {
        _isHealthy = false;
        return;
      }

      _attachTransport(transport);
      final ok = await _performUciHandshake();
      if (!ok) {
        await _teardownTransport();
        _isHealthy = false;
        return;
      }

      if (resolvedEvalFile != null) {
        final evalReady = await _configureEvalFileAndVerify(resolvedEvalFile);
        if (!evalReady) {
          await _teardownTransport();
          _isHealthy = false;
          return;
        }
        _evalFile = resolvedEvalFile.split(RegExp(r'[/\\]')).last;
      }
    } catch (_) {
      await _teardownTransport();
      _isHealthy = false;
    }
  }

  void _attachTransport(UciEngineTransport transport) {
    _transport = transport;
    _lastThreads = null;
    _lastHashMb = null;
    _lastMultiPv = null;

    transport.onExit.then((code) {
      if (identical(_transport, transport) && !_disposed) {
        _handleTransportFailure(
          'Stockfish transport exited unexpectedly with exit code $code',
        );
      }
    });
  }

  void _handleTransportFailure(String reason) {
    _isHealthy = false;
    if (_transport != null) {
      _transport = null;
    }
    _abortPendingWaiter?.call(reason);
  }

  Future<bool> _configureEvalFileAndVerify(String evalFilePath) {
    return _enqueue<bool>(() async {
      final transport = _transport;
      if (_disposed || !_isHealthy || transport == null) {
        return false;
      }
      transport.sendLine('setoption name EvalFile value $evalFilePath');
      await transport.flush();
      return await _sendIsReadyLocked(
        transport,
        timeout: const Duration(seconds: 12),
      );
    });
  }

  Future<bool> _performUciHandshake() {
    return _enqueue<bool>(() async {
      final transport = _transport;
      if (transport == null) {
        _isHealthy = false;
        return false;
      }

      final completer = Completer<bool>();
      StreamSubscription<String>? sub;
      _abortPendingWaiter = (reason) {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
      };

      sub = transport.lines.listen((raw) {
        final line = raw.trim();
        if (line.startsWith('id name ')) {
          _idName = line.substring('id name '.length).trim();
        } else if (line.startsWith('option name EvalFile ') &&
            line.contains(' default ')) {
          final idx = line.indexOf(' default ');
          _evalFile = line.substring(idx + ' default '.length).trim();
        } else if (line == 'uciok') {
          if (!completer.isCompleted) {
            completer.complete(true);
          }
        }
      });

      try {
        transport.sendLine('uci');
        await transport.flush();
        final result = await completer.future.timeout(
          commandTimeout,
          onTimeout: () => false,
        );
        _isHealthy = result;
        return result;
      } catch (_) {
        _isHealthy = false;
        return false;
      } finally {
        _abortPendingWaiter = null;
        await sub.cancel();
      }
    });
  }

  @override
  Future<bool> checkHealth() async {
    if (_disposed || _transport == null) {
      _isHealthy = false;
      return false;
    }
    try {
      return await _enqueue<bool>(() async {
        final transport = _transport;
        if (_disposed || transport == null) {
          _isHealthy = false;
          return false;
        }
        final ok = await _sendIsReadyLocked(transport);
        _isHealthy = ok;
        return ok;
      });
    } catch (_) {
      _isHealthy = false;
      return false;
    }
  }

  @override
  Future<void> newGame() async {
    if (_disposed) {
      throw StateError('StockfishEngineAdapter is disposed');
    }
    if (!_isHealthy || _transport == null) {
      if (refuseSilentFallback) {
        throw StateError('Stockfish engine is not healthy; cannot start newGame.');
      }
      return;
    }

    await _enqueue<void>(() async {
      final transport = _transport;
      if (_disposed || !_isHealthy || transport == null) {
        throw StateError('Stockfish engine became unavailable during newGame.');
      }
      transport.sendLine('ucinewgame');
      await transport.flush();
      final ready = await _sendIsReadyLocked(transport);
      if (!ready) {
        _isHealthy = false;
        throw StateError('Stockfish failed to respond readyok after ucinewgame.');
      }
    });
  }

  /// Sends UCI `stop` to any active search and prevents the current search
  /// from returning stale data while keeping the engine ready for subsequent calls.
  void cancelActiveSearch() {
    _cancelRequested = true;
    final transport = _transport;
    if (_hasActiveSearch && transport != null) {
      try {
        transport.sendLine('stop');
      } catch (_) {}
    }
  }

  @override
  Future<core.EngineAnalysisResult> analyse(
    String fen, {
    int multiPv = 1,
    required core.EngineBudget budget,
    CancelToken? cancel,
  }) async {
    if (_disposed) {
      throw StateError('StockfishEngineAdapter is disposed');
    }
    if (cancel?.isCancelled == true) {
      throw const EngineCancelledException();
    }
    if (!_isHealthy || _transport == null) {
      throw StateError(
        'Real Stockfish engine is unavailable (checkHealth=$_isHealthy). '
        'core.EngineServicePort.analyse refuses silent minimax fallback.',
      );
    }

    final normFen = core.EngineAnalysisResult.normalizeFen(fen);
    final board = ch.Chess.fromFEN(normFen);
    final legalMoves = board.generate_moves();
    if (legalMoves.isEmpty) {
      return core.EngineAnalysisResult(
        fen: normFen,
        engineVersion: engineVersion,
        budget: budget,
        lines: const [],
        nodes: 0,
      );
    }

    final effectiveMultiPv = math.min(math.max(1, multiPv), legalMoves.length);
    final searchOut = await _runSerializedUciSearch(
      fen: normFen,
      threads: budget.threads,
      hashMb: budget.hashMb,
      multiPv: effectiveMultiPv,
      goCommand: 'go nodes ${budget.nodes}',
      defaultNodes: budget.nodes,
      cancel: cancel,
    );

    final lines = searchOut.lines
        .map(
          (l) => core.EnginePvLine(
            multiPvRank: l.rank,
            cp: l.cp,
            mate: l.mate,
            winPercent: core.WinPercent.fromScore(cp: l.cp, mate: l.mate),
            moveUci: l.pv.first,
            pv: List<String>.unmodifiable(l.pv),
          ),
        )
        .toList();

    return core.EngineAnalysisResult(
      fen: normFen,
      engineVersion: engineVersion,
      budget: budget,
      lines: lines,
      nodes: searchOut.nodes,
    );
  }

  @override
  Future<EngineEvalEntity> evaluatePosition(
    String fen,
    EnginePresetConfig preset, {
    int multiPv = 1,
    CancelToken? cancel,
  }) async {
    if (_disposed) {
      throw StateError('StockfishEngineAdapter is disposed');
    }
    if (cancel?.isCancelled == true) {
      throw const EngineCancelledException();
    }
    if (!_isHealthy && refuseSilentFallback) {
      throw StateError(
        'Real Stockfish engine is not available (uciok check failed). Silent fallback to 2-ply minimax is refused.',
      );
    }

    final game = ch.Chess.fromFEN(fen);
    final legalMoves = game.generate_moves();

    // Terminal position check
    if (legalMoves.isEmpty) {
      final isMate = game.in_check;
      return EngineEvalEntity(
        positionKey: fen,
        cp: isMate ? null : 0,
        mate: isMate ? -1 : null,
        depth: preset.targetDepth,
        nodes: preset.fixedNodes ?? 0,
        pvUci: const [],
        multipv: const [],
        createdAt: DateTime.now().millisecondsSinceEpoch,
        isReliable: _isHealthy,
      );
    }

    // Native UCI Stockfish execution path when healthy
    if (_isHealthy && _transport != null) {
      final effectiveThreads = _thermalThrottled
          ? math.max(1, preset.threads ~/ 2)
          : preset.threads;
      final effectiveDepth = _thermalThrottled
          ? (preset.targetDepth - 2).clamp(8, 20)
          : preset.targetDepth;
      final effectiveMultiPv = math.min(math.max(1, multiPv), legalMoves.length);
      final goCommand = preset.fixedNodes != null
          ? 'go nodes ${preset.fixedNodes}'
          : 'go depth $effectiveDepth movetime ${preset.moveTimeMs}';

      final searchOut = await _runSerializedUciSearch(
        fen: fen,
        threads: effectiveThreads,
        hashMb: preset.hashMb,
        multiPv: effectiveMultiPv,
        goCommand: goCommand,
        defaultNodes: preset.fixedNodes ?? 0,
        cancel: cancel,
      );

      if (searchOut.lines.isEmpty) {
        throw StateError('Stockfish returned zero PV lines for non-terminal FEN: $fen');
      }

      final best = searchOut.lines.first;
      final topLines = searchOut.lines.map((s) {
        return <String, dynamic>{
          'uci': s.pv.first,
          'cp': s.cp,
          'mate': s.mate,
          'pv': s.pv,
        };
      }).toList();

      return EngineEvalEntity(
        positionKey: fen,
        cp: best.mate != null ? null : best.cp,
        mate: best.mate,
        depth: searchOut.depth > 0 ? searchOut.depth : effectiveDepth,
        nodes: searchOut.nodes,
        pvUci: best.pv,
        multipv: topLines,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        isReliable: true,
      );
    }

    // Fallback deterministic 2-ply minimax (marked isReliable: false)
    return _evaluateFallbackMinimax(game, fen, preset, multiPv);
  }

  Future<_UciSearchOutput> _runSerializedUciSearch({
    required String fen,
    required int threads,
    required int hashMb,
    required int multiPv,
    required String goCommand,
    required int defaultNodes,
    CancelToken? cancel,
  }) {
    return _enqueue<_UciSearchOutput>(() async {
      if (_disposed) {
        throw StateError('StockfishEngineAdapter is disposed');
      }
      if (cancel?.isCancelled == true) {
        throw const EngineCancelledException();
      }
      final transport = _transport;
      if (!_isHealthy || transport == null) {
        throw StateError('Stockfish transport is not healthy');
      }

      _cancelRequested = false;

      if (_lastThreads != threads) {
        transport.sendLine('setoption name Threads value $threads');
        _lastThreads = threads;
      }
      if (_lastHashMb != hashMb) {
        transport.sendLine('setoption name Hash value $hashMb');
        _lastHashMb = hashMb;
      }
      if (_lastMultiPv != multiPv) {
        transport.sendLine('setoption name MultiPV value $multiPv');
        _lastMultiPv = multiPv;
      }
      transport.sendLine('position fen $fen');
      await transport.flush();

      final ready = await _sendIsReadyLocked(transport);
      if (!ready) {
        _isHealthy = false;
        throw StateError('Stockfish did not answer readyok before search');
      }
      if (cancel?.isCancelled == true || _cancelRequested) {
        throw const EngineCancelledException();
      }

      final byDepth = <int, Map<int, _ParsedUciLine>>{};
      var actualNodes = defaultNodes;
      final bestmoveCompleter = Completer<void>();
      var stopSent = false;
      Object? failureError;

      final sub = transport.lines.listen((raw) {
        final line = raw.trim();
        if (line.startsWith('info ') &&
            line.contains(' score ') &&
            !line.contains('upperbound') &&
            !line.contains('lowerbound')) {
          final parsed = _parseInfoLine(line);
          if (parsed != null) {
            if (parsed.nodes != null) actualNodes = parsed.nodes!;
            byDepth.putIfAbsent(parsed.depth, () => {})[parsed.rank] = parsed;
          }
        } else if (line.startsWith('bestmove ')) {
          if (!bestmoveCompleter.isCompleted) {
            bestmoveCompleter.complete();
          }
        }
      });

      void triggerStop() {
        if (!stopSent && !_disposed && identical(_transport, transport)) {
          stopSent = true;
          _cancelRequested = true;
          try {
            transport.sendLine('stop');
          } catch (_) {}
        }
      }

      cancel?.addListener(triggerStop);
      _abortPendingWaiter = (reason) {
        failureError = StateError(reason);
        if (!bestmoveCompleter.isCompleted) {
          bestmoveCompleter.complete();
        }
      };

      _hasActiveSearch = true;
      try {
        transport.sendLine(goCommand);
        await transport.flush();

        await bestmoveCompleter.future.timeout(searchTimeout);
      } on TimeoutException {
        triggerStop();
        try {
          await bestmoveCompleter.future.timeout(const Duration(seconds: 2));
        } catch (_) {
          _isHealthy = false;
        }
        rethrow;
      } finally {
        _hasActiveSearch = false;
        _abortPendingWaiter = null;
        cancel?.removeListener(triggerStop);
        await sub.cancel();
      }

      if (failureError != null) {
        throw failureError!;
      }
      if (cancel?.isCancelled == true || _cancelRequested) {
        _cancelRequested = false;
        throw const EngineCancelledException();
      }

      return _selectBestDepthLines(byDepth, multiPv, actualNodes);
    });
  }

  Future<bool> _sendIsReadyLocked(
    UciEngineTransport transport, {
    Duration? timeout,
  }) async {
    final completer = Completer<bool>();
    final prevAbort = _abortPendingWaiter;
    _abortPendingWaiter = (reason) {
      if (!completer.isCompleted) completer.complete(false);
    };
    final sub = transport.lines.listen((line) {
      if (line.trim() == 'readyok' && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    try {
      transport.sendLine('isready');
      await transport.flush();
      return await completer.future.timeout(
        timeout ?? commandTimeout,
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    } finally {
      _abortPendingWaiter = prevAbort;
      await sub.cancel();
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serialQueue = _serialQueue.then((_) async {
      try {
        final result = await action();
        if (!completer.isCompleted) completer.complete(result);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static final RegExp _depthRe = RegExp(r'\bdepth (\d+)');
  static final RegExp _mpvRe = RegExp(r'\bmultipv (\d+)');
  static final RegExp _cpRe = RegExp(r'\bscore cp (-?\d+)');
  static final RegExp _mateRe = RegExp(r'\bscore mate (-?\d+)');
  static final RegExp _nodesRe = RegExp(r'\bnodes (\d+)');
  static final RegExp _pvRe = RegExp(r' pv (.+)$');

  static _ParsedUciLine? _parseInfoLine(String line) {
    final pvMatch = _pvRe.firstMatch(line);
    if (pvMatch == null) return null;
    final pv = pvMatch
        .group(1)!
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (pv.isEmpty) return null;

    final depth = int.tryParse(_depthRe.firstMatch(line)?.group(1) ?? '') ?? 0;
    final rank = int.tryParse(_mpvRe.firstMatch(line)?.group(1) ?? '') ?? 1;
    final cpStr = _cpRe.firstMatch(line)?.group(1);
    final mateStr = _mateRe.firstMatch(line)?.group(1);
    final nodesStr = _nodesRe.firstMatch(line)?.group(1);

    final mate = mateStr != null ? int.tryParse(mateStr) : null;
    final cp = (mate == null && cpStr != null) ? int.tryParse(cpStr) : null;
    if (cp == null && mate == null) return null;

    return _ParsedUciLine(
      depth: depth,
      rank: rank,
      cp: cp,
      mate: mate,
      nodes: nodesStr != null ? int.tryParse(nodesStr) : null,
      pv: pv,
    );
  }

  static _UciSearchOutput _selectBestDepthLines(
    Map<int, Map<int, _ParsedUciLine>> byDepth,
    int requestedMultiPv,
    int actualNodes,
  ) {
    if (byDepth.isEmpty) {
      return _UciSearchOutput(depth: 0, nodes: actualNodes, lines: const []);
    }
    final depthsDesc = byDepth.keys.toList()..sort((a, b) => b.compareTo(a));
    var chosenDepth = depthsDesc.first;
    for (final d in depthsDesc) {
      if (byDepth[d]!.length >= requestedMultiPv) {
        chosenDepth = d;
        break;
      }
    }
    final rankMap = byDepth[chosenDepth]!;
    final lines = rankMap.values.toList()
      ..sort((a, b) => a.rank.compareTo(b.rank));
    return _UciSearchOutput(
      depth: chosenDepth,
      nodes: actualNodes,
      lines: lines,
    );
  }

  EngineEvalEntity _evaluateFallbackMinimax(
    ch.Chess game,
    String fen,
    EnginePresetConfig preset,
    int multiPv,
  ) {
    final legalMoves = game.generate_moves();
    final scoredMoves = <_ScoredMove>[];
    for (final m in legalMoves) {
      final uci = '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}';
      final san = game.move_to_san(m);
      game.move(m);

      int? mateScore;
      int cpScore;

      if (game.in_checkmate) {
        mateScore = 1;
        cpScore = 1000;
      } else if (game.in_draw || game.in_stalemate) {
        cpScore = 0;
      } else {
        final oppMoves = game.generate_moves();
        var bestOppReplyCp = -99999;
        ch.Move? bestOppMove;
        var oppDeliversMate = false;

        for (final oppM in oppMoves) {
          game.move(oppM);
          if (game.in_checkmate) {
            oppDeliversMate = true;
            bestOppReplyCp = 1000;
            bestOppMove = oppM;
            game.undo_move();
            break;
          }
          final staticCp = -_evaluateBoardStaticCp(game);
          if (staticCp > bestOppReplyCp) {
            bestOppReplyCp = staticCp;
            bestOppMove = oppM;
          }
          game.undo_move();
        }

        if (oppDeliversMate) {
          mateScore = -1;
          cpScore = -1000;
        } else {
          cpScore = -bestOppReplyCp;
        }

        final pvLine = <String>[uci];
        if (bestOppMove != null) {
          pvLine.add(
            '${bestOppMove.fromAlgebraic}${bestOppMove.toAlgebraic}${bestOppMove.promotion?.name ?? ''}',
          );
        }
        scoredMoves.add(
          _ScoredMove(
            uci: uci,
            san: san,
            cp: cpScore.clamp(-1000, 1000),
            mate: mateScore,
            pv: pvLine,
          ),
        );
        game.undo_move();
        continue;
      }

      scoredMoves.add(
        _ScoredMove(
          uci: uci,
          san: san,
          cp: cpScore,
          mate: mateScore,
          pv: [uci],
        ),
      );
      game.undo_move();
    }

    scoredMoves.sort((a, b) => b.cp.compareTo(a.cp));
    final best = scoredMoves.first;
    final topLines = scoredMoves.take(multiPv.clamp(1, 3)).map((s) {
      return <String, dynamic>{
        'uci': s.uci,
        'san': s.san,
        'cp': s.cp,
        'mate': s.mate,
        'pv': s.pv,
      };
    }).toList();

    return EngineEvalEntity(
      positionKey: fen,
      cp: best.mate != null ? null : best.cp,
      mate: best.mate,
      depth: _thermalThrottled
          ? (preset.targetDepth - 2).clamp(8, 20)
          : preset.targetDepth,
      nodes: preset.fixedNodes ?? (legalMoves.length * 450),
      pvUci: best.pv,
      multipv: topLines,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      isReliable: false,
    );
  }

  /// Static evaluation in centipawns from side-to-move's perspective.
  int _evaluateBoardStaticCp(ch.Chess game) {
    var whiteCp = 0;
    var blackCp = 0;

    for (var i = 0; i < 128; i++) {
      if ((i & 0x88) != 0) continue;
      final p = game.board[i];
      if (p == null) continue;
      final basePts =
          (SeeEvaluator.piecePoints[p.type.name.toLowerCase()] ?? 0) * 100;
      if (basePts >= 10000) continue;

      final rank = 7 - (i >> 4);
      final file = i & 7;
      final centerDist = ((3.5 - file).abs() + (3.5 - rank).abs()).round();
      final positionalBonus = (7 - centerDist) * 6;

      if (p.color == ch.Color.WHITE) {
        whiteCp +=
            basePts + positionalBonus + (p.type == ch.PieceType.PAWN ? rank * 5 : 0);
      } else {
        blackCp += basePts +
            positionalBonus +
            (p.type == ch.PieceType.PAWN ? (7 - rank) * 5 : 0);
      }
    }

    final diff = whiteCp - blackCp;
    return game.turn == ch.Color.WHITE ? diff : -diff;
  }

  Future<void> _teardownTransport() async {
    final transport = _transport;
    _transport = null;
    _isHealthy = false;
    _abortPendingWaiter?.call('Stockfish transport torn down');
    if (transport != null) {
      await transport.close();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _teardownTransport();
  }
}

/// Bridges an existing [EngineService] (e.g., mocks or [StockfishEngineAdapter])
/// to the pure-Dart [core.EngineServicePort] interface with strict reliability checking.
class EngineServiceToCoreAdapter implements core.EngineServicePort {
  final EngineService inner;
  final String presetId;
  final bool allowUnreliableFallback;

  const EngineServiceToCoreAdapter(
    this.inner, {
    this.presetId = 'balanced',
    this.allowUnreliableFallback = false,
  });

  @override
  String get engineVersion => inner.engineVersion;

  @override
  Future<bool> checkHealth() => inner.checkHealth();

  @override
  Future<void> newGame() async {
    if (inner is StockfishEngineAdapter) {
      await (inner as StockfishEngineAdapter).newGame();
    }
  }

  @override
  Future<core.EngineAnalysisResult> analyse(
    String fen, {
    int multiPv = 1,
    required core.EngineBudget budget,
    CancelToken? cancel,
  }) async {
    if (inner is StockfishEngineAdapter) {
      final sf = inner as StockfishEngineAdapter;
      if (sf.isHealthy || !allowUnreliableFallback) {
        return sf.analyse(
          fen,
          multiPv: multiPv,
          budget: budget,
          cancel: cancel,
        );
      }
    }
    if (cancel?.isCancelled == true) {
      throw const EngineCancelledException();
    }

    final preset = EnginePresetConfig(
      id: 'budget_$presetId',
      displayName: 'Deterministic Fixed Nodes (${budget.nodes})',
      threads: budget.threads,
      hashMb: budget.hashMb,
      moveTimeMs: 400,
      targetDepth: 16,
      defaultMultiPv: multiPv,
      fixedNodes: budget.nodes,
    );

    final raw = await inner.evaluatePosition(fen, preset, multiPv: multiPv);
    if (!raw.isReliable && !allowUnreliableFallback) {
      throw StateError(
        'Engine evaluation marked unreliable for $fen; refusing silent minimax fallback.',
      );
    }

    final lines = <core.EnginePvLine>[];
    if (raw.multipv.isNotEmpty) {
      for (var i = 0; i < raw.multipv.length; i++) {
        final item = raw.multipv[i];
        final pv = (item['pv'] as List<dynamic>?)?.cast<String>() ??
            (item['uci'] != null ? <String>[item['uci'] as String] : const <String>[]);
        if (pv.isEmpty) continue;
        final cp = item['cp'] as int?;
        final mate = item['mate'] as int?;
        lines.add(
          core.EnginePvLine(
            multiPvRank: i + 1,
            cp: cp,
            mate: mate,
            winPercent: core.WinPercent.fromScore(cp: cp, mate: mate),
            moveUci: pv.first,
            pv: pv,
          ),
        );
      }
    } else if (raw.pvUci.isNotEmpty) {
      lines.add(
        core.EnginePvLine(
          multiPvRank: 1,
          cp: raw.cp,
          mate: raw.mate,
          winPercent: core.WinPercent.fromScore(cp: raw.cp, mate: raw.mate),
          moveUci: raw.pvUci.first,
          pv: raw.pvUci,
        ),
      );
    }

    return core.EngineAnalysisResult(
      fen: core.EngineAnalysisResult.normalizeFen(fen),
      engineVersion: inner.engineVersion,
      budget: budget,
      lines: lines,
      nodes: raw.nodes,
    );
  }

  @override
  Future<void> dispose() => inner.dispose();
}

class _ParsedUciLine {
  final int depth;
  final int rank;
  final int? cp;
  final int? mate;
  final int? nodes;
  final List<String> pv;

  const _ParsedUciLine({
    required this.depth,
    required this.rank,
    this.cp,
    this.mate,
    this.nodes,
    required this.pv,
  });
}

class _UciSearchOutput {
  final int depth;
  final int nodes;
  final List<_ParsedUciLine> lines;

  const _UciSearchOutput({
    required this.depth,
    required this.nodes,
    required this.lines,
  });
}

class _ScoredMove {
  final String uci;
  final String san;
  final int cp;
  final int? mate;
  final List<String> pv;

  const _ScoredMove({
    required this.uci,
    required this.san,
    required this.cp,
    this.mate,
    required this.pv,
  });
}
