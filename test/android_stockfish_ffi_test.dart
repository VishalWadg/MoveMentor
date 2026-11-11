import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:chess_review_core/chess_review_core.dart' as core;
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/adapters/engine/android_nnue_asset_loader.dart';
import 'package:movementor/src/adapters/engine/ffi_uci_transport.dart';
import 'package:movementor/src/adapters/engine/stockfish_engine_adapter.dart';

class _FakeAssetBundle extends CachingAssetBundle {
  final Map<String, Uint8List> _assets;
  int loadCount = 0;

  _FakeAssetBundle(this._assets);

  @override
  Future<ByteData> load(String key) async {
    loadCount++;
    final bytes = _assets[key];
    if (bytes == null) {
      throw StateError('Asset not found: $key');
    }
    return ByteData.sublistView(bytes);
  }
}

class _FakeStockfishFfiBindings implements StockfishFfiBindings {
  String? capturedDirHint;
  final List<String> sentCommands = [];
  final List<int> freedAddresses = [];
  bool stopCalled = false;

  late final void Function(Pointer<Utf8>) _emitLine;
  late final void Function(int) _emitExit;

  @override
  int start(
    Pointer<Utf8> binaryDirHint,
    Pointer<NativeFunction<Void Function(Pointer<Utf8>)>> onLine,
    Pointer<NativeFunction<Void Function(Int32)>> onExit,
  ) {
    capturedDirHint = binaryDirHint.toDartString();
    _emitLine = onLine.asFunction<void Function(Pointer<Utf8>)>();
    _emitExit = onExit.asFunction<void Function(int)>();
    return 0;
  }

  @override
  int send(Pointer<Utf8> command) {
    final cmd = command.toDartString();
    sentCommands.add(cmd);
    if (cmd == 'uci') {
      emitFromNative('id name Stockfish 19 Android-FFI');
      emitFromNative('option name EvalFile type string default nn-1a298aa575a0.nnue');
      emitFromNative('uciok');
    } else if (cmd == 'isready') {
      emitFromNative('readyok');
    } else if (cmd == 'quit') {
      _emitExit(0);
    }
    return 0;
  }

  void emitFromNative(String line) {
    final ptr = line.toNativeUtf8();
    _emitLine(ptr);
  }

  @override
  void stop() {
    stopCalled = true;
  }

  @override
  void freeNativeString(Pointer<Void> ptr) {
    freedAddresses.add(ptr.address);
    calloc.free(ptr);
  }
}

class _FakeUciTransport implements UciEngineTransport {
  final StreamController<String> _lines = StreamController<String>.broadcast();
  final Completer<int> _exit = Completer<int>();
  final List<String> sent = [];
  final void Function(String cmd, _FakeUciTransport t) onSend;
  bool closed = false;

  _FakeUciTransport(this.onSend);

  void emit(String line) {
    if (!_lines.isClosed) {
      _lines.add(line);
    }
  }

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<int> get onExit => _exit.future;

  @override
  void sendLine(String command) {
    sent.add(command);
    onSend(command, this);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    closed = true;
    if (!_exit.isCompleted) _exit.complete(0);
    if (!_lines.isClosed) await _lines.close();
  }
}

void main() {
  group('Android FFI Stockfish & NNUE Asset Extraction', () {
    test('resolveAndroidNnueFilePath extracts once atomically and short-circuits on cache hit', () async {
      final tempDir = await Directory.systemTemp.createTemp('movementor_nnue_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final fakeNetBytes = Uint8List.fromList(List<int>.generate(256, (i) => i % 251));
      final bundle = _FakeAssetBundle({androidNnueAssetPath: fakeNetBytes});

      // Missing asset in bundle degrades cleanly to null
      final emptyBundle = _FakeAssetBundle(const {});
      final missingPath = await resolveAndroidNnueFilePath(
        bundle: emptyBundle,
        supportDirProvider: () async => tempDir,
        expectedBytes: fakeNetBytes.length,
      );
      expect(missingPath, isNull);

      // Valid asset extracts atomically to target path
      final firstPath = await resolveAndroidNnueFilePath(
        bundle: bundle,
        supportDirProvider: () async => tempDir,
        expectedBytes: fakeNetBytes.length,
      );
      expect(firstPath, isNotNull);
      expect(File(firstPath!).existsSync(), isTrue);
      expect(File(firstPath).readAsBytesSync(), equals(fakeNetBytes));
      expect(bundle.loadCount, equals(1));

      // Second call skips reloading from AssetBundle when size matches
      final secondPath = await resolveAndroidNnueFilePath(
        bundle: bundle,
        supportDirProvider: () async => tempDir,
        expectedBytes: fakeNetBytes.length,
      );
      expect(secondPath, equals(firstPath));
      expect(bundle.loadCount, equals(1));
    });

    test('FfiUciTransport bridges native C callbacks, frees every native string, and stops cleanly', () async {
      final bindings = _FakeStockfishFfiBindings();
      final transport = await FfiUciTransport.start(
        evalDir: '/data/user/0/com.movementor.app/files',
        bindings: bindings,
      );

      expect(bindings.capturedDirHint, equals('/data/user/0/com.movementor.app/files'));

      final received = <String>[];
      final sub = transport.lines.listen(received.add);

      transport.sendLine('uci');
      transport.sendLine('isready');

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        bindings.sentCommands,
        equals(['uci', 'isready']),
      );
      expect(
        received,
        containsAllInOrder([
          'id name Stockfish 19 Android-FFI',
          'option name EvalFile type string default nn-1a298aa575a0.nnue',
          'uciok',
          'readyok',
        ]),
      );
      // Every emitted native pointer must be freed via sf_ffi_free
      expect(bindings.freedAddresses.length, equals(4));

      await transport.close();
      await sub.cancel();
      expect(bindings.stopCalled, isTrue);
      expect(bindings.sentCommands.last, equals('quit'));
    });

    test('StockfishEngineAdapter refuses FFI without NNUE net and coalesces concurrent FFI init with EvalFile setup', () async {
      // Case 1: missing NNUE file prevents starting native transport cleanly
      var starterCalls = 0;
      final missingAdapter = StockfishEngineAdapter(
        refuseSilentFallback: true,
        androidEvalFileResolver: () async => null,
        ffiTransportStarter: ({required evalDir}) async {
          starterCalls++;
          throw StateError('Should not launch without NNUE');
        },
      );
      await missingAdapter.init();
      expect(starterCalls, equals(0));
      expect(missingAdapter.isHealthy, isFalse);
      expect(missingAdapter.isFallbackEngine, isTrue);
      await missingAdapter.dispose();

      // Case 2: valid NNUE file coalesces concurrent init() calls & sets EvalFile
      final tempDir = await Directory.systemTemp.createTemp('movementor_eval_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final fakeNnue = File('${tempDir.path}${Platform.pathSeparator}$androidNnueFilename');
      fakeNnue.writeAsBytesSync([1, 2, 3, 4]);

      var launches = 0;
      late _FakeUciTransport activeTransport;
      final adapter = StockfishEngineAdapter(
        refuseSilentFallback: true,
        androidEvalFileResolver: () async => fakeNnue.path,
        ffiTransportStarter: ({required evalDir}) async {
          launches++;
          expect(evalDir, equals(tempDir.path));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          activeTransport = _FakeUciTransport((cmd, t) {
            if (cmd == 'uci') {
              t.emit('id name Stockfish 19 Android-FFI');
              t.emit('uciok');
            } else if (cmd == 'isready') {
              t.emit('readyok');
            } else if (cmd.startsWith('go ')) {
              t.emit('info depth 10 multipv 1 score cp 32 nodes 50000 pv e2e4 e7e5');
              t.emit('info depth 10 multipv 2 score cp 15 nodes 50000 pv d2d4 d7d5');
              t.emit('bestmove e2e4');
            }
          });
          return activeTransport;
        },
      );

      // Coalesce concurrent startup inits
      await Future.wait([adapter.init(), adapter.init(), adapter.init()]);
      expect(launches, equals(1));
      expect(adapter.isHealthy, isTrue);
      expect(adapter.isFallbackEngine, isFalse);
      expect(adapter.engineVersion, equals('Stockfish 19 Android-FFI ($androidNnueFilename)'));
      expect(
        activeTransport.sent,
        contains('setoption name EvalFile value ${fakeNnue.path}'),
      );

      final res = await adapter.analyse(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        multiPv: 2,
        budget: const core.EngineBudget(nodes: 50000, threads: 1, hashMb: 16),
      );
      expect(res.lines.length, equals(2));
      expect(res.topLine!.moveUci, equals('e2e4'));

      await adapter.dispose();
      expect(activeTransport.closed, isTrue);
    });
  });
}
