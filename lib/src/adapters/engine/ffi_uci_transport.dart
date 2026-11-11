import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'uci_transport.dart';

typedef _SfStartNative = Int32 Function(
  Pointer<Utf8> binaryDirHint,
  Pointer<NativeFunction<Void Function(Pointer<Utf8>)>> onLine,
  Pointer<NativeFunction<Void Function(Int32)>> onExit,
);
typedef _SfStartDart = int Function(
  Pointer<Utf8> binaryDirHint,
  Pointer<NativeFunction<Void Function(Pointer<Utf8>)>> onLine,
  Pointer<NativeFunction<Void Function(Int32)>> onExit,
);

typedef _SfSendNative = Int32 Function(Pointer<Utf8> command);
typedef _SfSendDart = int Function(Pointer<Utf8> command);

typedef _SfStopNative = Void Function();
typedef _SfStopDart = void Function();

typedef _SfFreeNative = Void Function(Pointer<Void> ptr);
typedef _SfFreeDart = void Function(Pointer<Void> ptr);

/// Native C API contract implemented by `libmovementor_stockfish.so`.
abstract interface class StockfishFfiBindings {
  int start(
    Pointer<Utf8> binaryDirHint,
    Pointer<NativeFunction<Void Function(Pointer<Utf8>)>> onLine,
    Pointer<NativeFunction<Void Function(Int32)>> onExit,
  );
  int send(Pointer<Utf8> command);
  void stop();
  void freeNativeString(Pointer<Void> ptr);
}

class DynamicLibraryStockfishFfiBindings implements StockfishFfiBindings {
  final _SfStartDart _start;
  final _SfSendDart _send;
  final _SfStopDart _stop;
  final _SfFreeDart _free;

  DynamicLibraryStockfishFfiBindings(DynamicLibrary lib)
      : _start = lib.lookupFunction<_SfStartNative, _SfStartDart>('sf_ffi_start'),
        _send = lib.lookupFunction<_SfSendNative, _SfSendDart>('sf_ffi_send'),
        _stop = lib.lookupFunction<_SfStopNative, _SfStopDart>('sf_ffi_stop'),
        _free = lib.lookupFunction<_SfFreeNative, _SfFreeDart>('sf_ffi_free');

  factory DynamicLibraryStockfishFfiBindings.openAndroid() {
    return DynamicLibraryStockfishFfiBindings(
      DynamicLibrary.open('libmovementor_stockfish.so'),
    );
  }

  @override
  int start(
    Pointer<Utf8> binaryDirHint,
    Pointer<NativeFunction<Void Function(Pointer<Utf8>)>> onLine,
    Pointer<NativeFunction<Void Function(Int32)>> onExit,
  ) =>
      _start(binaryDirHint, onLine, onExit);

  @override
  int send(Pointer<Utf8> command) => _send(command);

  @override
  void stop() => _stop();

  @override
  void freeNativeString(Pointer<Void> ptr) => _free(ptr);
}

typedef FfiTransportStarter = Future<UciEngineTransport> Function({
  required String evalDir,
});

/// In-process native FFI transport backed by `libmovementor_stockfish.so` via
/// [NativeCallable.listener] for thread-safe asynchronous UCI output delivery.
class FfiUciTransport implements UciEngineTransport {
  final StockfishFfiBindings _bindings;
  final StreamController<String> _linesCtrl =
      StreamController<String>.broadcast();
  final Completer<int> _exitCompleter = Completer<int>();

  late final NativeCallable<Void Function(Pointer<Utf8>)> _lineCallable;
  late final NativeCallable<Void Function(Int32)> _exitCallable;
  bool _closed = false;

  FfiUciTransport._(this._bindings);

  static Future<FfiUciTransport> start({
    required String evalDir,
    StockfishFfiBindings? bindings,
  }) async {
    final resolvedBindings =
        bindings ?? DynamicLibraryStockfishFfiBindings.openAndroid();
    final transport = FfiUciTransport._(resolvedBindings);

    transport._lineCallable =
        NativeCallable<Void Function(Pointer<Utf8>)>.listener(
      (Pointer<Utf8> ptr) {
        try {
          if (ptr != nullptr) {
            final line = ptr.toDartString().replaceAll('\r', '');
            if (!transport._linesCtrl.isClosed) {
              transport._linesCtrl.add(line);
            }
          }
        } finally {
          if (ptr != nullptr) {
            transport._bindings.freeNativeString(ptr.cast<Void>());
          }
        }
      },
    );

    transport._exitCallable = NativeCallable<Void Function(Int32)>.listener(
      (int code) {
        if (!transport._exitCompleter.isCompleted) {
          transport._exitCompleter.complete(code);
        }
        if (!transport._linesCtrl.isClosed) {
          transport._linesCtrl.close();
        }
      },
    );

    final dirPtr = evalDir.toNativeUtf8();
    final int rc;
    try {
      rc = resolvedBindings.start(
        dirPtr,
        transport._lineCallable.nativeFunction,
        transport._exitCallable.nativeFunction,
      );
    } finally {
      calloc.free(dirPtr);
    }

    if (rc != 0) {
      transport._lineCallable.close();
      transport._exitCallable.close();
      await transport._linesCtrl.close();
      throw StateError('sf_ffi_start returned non-zero status: $rc');
    }

    return transport;
  }

  @override
  Stream<String> get lines => _linesCtrl.stream;

  @override
  Future<int> get onExit => _exitCompleter.future;

  @override
  void sendLine(String command) {
    if (_closed) return;
    _sendRaw(command);
  }

  void _sendRaw(String command) {
    final cmdPtr = command.toNativeUtf8();
    try {
      _bindings.send(cmdPtr);
    } finally {
      calloc.free(cmdPtr);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _sendRaw('quit');
    } catch (_) {}
    try {
      _bindings.stop();
    } catch (_) {}
    await Future.any([
      _exitCompleter.future.catchError((_) => -1),
      Future<void>.delayed(const Duration(milliseconds: 500)),
    ]);
    // Yield a microtask/event turn so any already-posted listener callbacks free strings before close.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _lineCallable.close();
    _exitCallable.close();
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(-1);
    }
    if (!_linesCtrl.isClosed) {
      await _linesCtrl.close();
    }
  }
}
