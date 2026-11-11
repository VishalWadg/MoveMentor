import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/adapters/engine/stockfish_engine_adapter.dart';
import 'package:movementor/src/ports/ports.dart';

void main() {
  group('Engine Health & Fallback Safety Tests (Phase 0b)', () {
    test('checkHealth returns false and flags fallback when binary is missing', () async {
      final engine = StockfishEngineAdapter(
        customStockfishBinaryPath: 'non_existent_stockfish_binary.exe',
      );
      await engine.init();

      final healthy = await engine.checkHealth();
      expect(healthy, isFalse);
      expect(engine.isFallbackEngine, isTrue);
      expect(engine.engineVersion, contains('UNRELIABLE-FALLBACK'));
    });

    test('fallback minimax marks engine eval as isReliable: false', () async {
      final engine = StockfishEngineAdapter();
      await engine.init();

      final eval = await engine.evaluatePosition(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        EnginePresetConfig.fast,
      );

      expect(eval.isReliable, isFalse,
          reason: 'Silent fallback minimax must never claim to be reliable');
    });

    test('refuseSilentFallback: true throws StateError instead of running fake minimax', () async {
      final engine = StockfishEngineAdapter(refuseSilentFallback: true);
      await engine.init();

      expect(
        () => engine.evaluatePosition(
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          EnginePresetConfig.fast,
        ),
        throwsStateError,
      );
    });
  });
}
