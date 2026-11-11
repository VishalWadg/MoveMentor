import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// Abstraction over a UCI engine communication channel (CLI process pipes or
/// native in-process C++ FFI bridge).
abstract interface class UciEngineTransport {
  Stream<String> get lines;
  Future<int> get onExit;
  void sendLine(String command);
  Future<void> flush();
  Future<void> close();
}

/// Standard stdin/stdout transport backed by a spawned OS executable [Process].
class ProcessUciTransport implements UciEngineTransport {
  final Process _process;
  final StreamController<String> _linesCtrl =
      StreamController<String>.broadcast();
  final Completer<int> _exitCompleter = Completer<int>();
  late final StreamSubscription<String> _stdoutSub;
  late final StreamSubscription<List<int>> _stderrSub;
  bool _closed = false;

  ProcessUciTransport(this._process) {
    _stdoutSub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (!_linesCtrl.isClosed) {
          _linesCtrl.add(line);
        }
      },
      onError: (_) {},
    );

    // Drain stderr continuously to prevent child process pipe stalls.
    _stderrSub = _process.stderr.listen((_) {}, onError: (_) {});

    _process.exitCode.then((code) {
      if (!_exitCompleter.isCompleted) {
        _exitCompleter.complete(code);
      }
      if (!_linesCtrl.isClosed) {
        _linesCtrl.close();
      }
    });
  }

  @override
  Stream<String> get lines => _linesCtrl.stream;

  @override
  Future<int> get onExit => _exitCompleter.future;

  @override
  void sendLine(String command) {
    if (_closed) return;
    _process.stdin.writeln(command);
  }

  @override
  Future<void> flush() async {
    if (_closed) return;
    await _process.stdin.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _process.stdin.writeln('quit');
      await _process.stdin.flush().timeout(const Duration(milliseconds: 250));
    } catch (_) {}
    await Future.any([
      _process.exitCode.catchError((_) => -1),
      Future<void>.delayed(const Duration(milliseconds: 350)),
    ]);
    try {
      _process.kill();
    } catch (_) {}
    try {
      await _stdoutSub.cancel();
    } catch (_) {}
    try {
      await _stderrSub.cancel();
    } catch (_) {}
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(-1);
    }
    if (!_linesCtrl.isClosed) {
      await _linesCtrl.close();
    }
  }
}
