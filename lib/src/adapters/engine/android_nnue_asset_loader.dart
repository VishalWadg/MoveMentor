import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Filename and expected byte count of the pinned Stockfish 19 NNUE network.
const String androidNnueFilename = 'nn-1a298aa575a0.nnue';
const String androidNnueAssetPath = 'assets/nnue/$androidNnueFilename';
const int androidNnueExpectedBytes = 98511183;

/// Resolves and atomically extracts the bundled Android NNUE network asset
/// into app support storage so `libmovementor_stockfish.so` can load it via
/// standard filesystem I/O with zero re-extraction on subsequent launches.
///
/// Returns `null` when the `.nnue` asset is absent (e.g., dev builds before
/// running `tool/prepare_android_stockfish.sh`), allowing callers to degrade
/// cleanly rather than crashing inside Stockfish's `verify_network()`.
Future<String?> resolveAndroidNnueFilePath({
  AssetBundle? bundle,
  Future<Directory> Function()? supportDirProvider,
  int expectedBytes = androidNnueExpectedBytes,
}) async {
  try {
    final dir = await (supportDirProvider ?? getApplicationSupportDirectory)();
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final target = File('${dir.path}${Platform.pathSeparator}$androidNnueFilename');
    if (target.existsSync() && target.lengthSync() == expectedBytes) {
      return target.path;
    }

    final assetBundle = bundle ?? rootBundle;
    final data = await assetBundle.load(androidNnueAssetPath);
    if (data.lengthInBytes <= 0) {
      return null;
    }

    final tmp = File('${target.path}.tmp');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await tmp.writeAsBytes(bytes, flush: true);
    if (target.existsSync()) {
      await target.delete();
    }
    await tmp.rename(target.path);
    return target.path;
  } catch (_) {
    return null;
  }
}
