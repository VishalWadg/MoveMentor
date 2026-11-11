import 'dart:convert';
import 'dart:io';
import 'package:chess/chess.dart' as ch;
import 'package:chess_review_core/chess_review_core.dart' as core;
import '../../domain/chess/fen_normalizer.dart';
import 'sqlite_storage_adapter.dart';

/// App-layer [core.OpeningBookPort] adapter bridging the Flutter asset bundle,
/// disk ECO JSON files, and [StorageRepository] while keeping [chess_review_core]
/// strictly pure Dart.
class OpeningBookAdapter extends core.OpeningBookPort {
  final Map<String, core.OpeningEntry> _byExactEpd = {};
  final Map<String, List<core.OpeningEntry>> _byNoEpKey = {};
  final StorageRepository? _storage;

  OpeningBookAdapter._({
    StorageRepository? storage,
  }) : _storage = storage;

  /// Creates an adapter backed by [storage], optionally auto-hydrating from
  /// [defaultAssetPath] on disk when [loadDiskAssetIfPresent] is true and the
  /// repository only holds the minimal initial seed set.
  factory OpeningBookAdapter.fromStorage(
    StorageRepository storage, {
    String defaultAssetPath = 'assets/openings/eco_openings.json',
    bool loadDiskAssetIfPresent = true,
  }) {
    final adapter = OpeningBookAdapter._(storage: storage);
    if (loadDiskAssetIfPresent && File(defaultAssetPath).existsSync()) {
      final raw = File(defaultAssetPath).readAsStringSync();
      final decoded =
          (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      adapter._ingestRawEntries(decoded);
      storage.loadOpenings(decoded);
    }
    return adapter;
  }

  /// Creates an adapter from in-memory JSON-like opening records.
  factory OpeningBookAdapter.fromEntries(
    List<Map<String, dynamic>> entries, {
    StorageRepository? mirrorToStorage,
  }) {
    final adapter = OpeningBookAdapter._(storage: mirrorToStorage);
    adapter._ingestRawEntries(entries);
    mirrorToStorage?.loadOpenings(entries);
    return adapter;
  }

  /// Creates an adapter synchronously by decoding raw ECO JSON string.
  factory OpeningBookAdapter.fromJsonString(
    String jsonContent, {
    StorageRepository? mirrorToStorage,
  }) {
    final decoded =
        (jsonDecode(jsonContent) as List<dynamic>).cast<Map<String, dynamic>>();
    return OpeningBookAdapter.fromEntries(
      decoded,
      mirrorToStorage: mirrorToStorage,
    );
  }

  /// Creates an adapter synchronously from a local ECO JSON file path.
  factory OpeningBookAdapter.fromFileSync(
    String filePath, {
    StorageRepository? mirrorToStorage,
  }) {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw StateError('Opening book file not found: $filePath');
    }
    return OpeningBookAdapter.fromJsonString(
      file.readAsStringSync(),
      mirrorToStorage: mirrorToStorage,
    );
  }

  /// Loads `assets/openings/eco_openings.json` asynchronously via an asset loader
  /// callback (e.g., passing Flutter's `rootBundle.loadString`).
  static Future<OpeningBookAdapter> fromAssetLoader(
    Future<String> Function(String path) loadString, {
    String assetPath = 'assets/openings/eco_openings.json',
    StorageRepository? mirrorToStorage,
  }) async {
    final jsonContent = await loadString(assetPath);
    return OpeningBookAdapter.fromJsonString(
      jsonContent,
      mirrorToStorage: mirrorToStorage,
    );
  }

  int get entryCount => _byExactEpd.length;

  /// Dynamically loads additional raw ECO entries into this live adapter
  /// (and mirrors to linked [StorageRepository] if configured).
  void loadEntries(List<Map<String, dynamic>> entries) {
    _ingestRawEntries(entries);
    _storage?.loadOpenings(entries);
  }

  /// Dynamically decodes and loads raw ECO JSON entries into this live adapter.
  void loadJsonString(String jsonContent) {
    final decoded =
        (jsonDecode(jsonContent) as List<dynamic>).cast<Map<String, dynamic>>();
    loadEntries(decoded);
  }

  void _ingestRawEntries(List<Map<String, dynamic>> entries) {
    for (final raw in entries) {
      final rawEpd = (raw['epd'] as String?)?.trim() ?? '';
      final eco = (raw['eco'] as String?)?.trim() ?? '';
      final name = (raw['name'] as String?)?.trim() ?? '';
      if (rawEpd.isEmpty || eco.isEmpty || name.isEmpty) continue;

      final epd = core.OpeningBookPort.fenToEpd(rawEpd);
      final parsedName = _splitNameAndVariation(name, raw['variation'] as String?);
      final entry = core.OpeningEntry(
        eco: eco,
        name: parsedName.name,
        variation: parsedName.variation,
        epd: epd,
      );
      _byExactEpd[epd] = entry;
      _byNoEpKey.putIfAbsent(_threeFieldKey(epd), () => []).add(entry);
    }
  }

  @override
  core.OpeningEntry? lookupByEpd(String epd) {
    final normInput = core.OpeningBookPort.fenToEpd(epd);
    final exact = _byExactEpd[normInput];
    if (exact != null) return exact;

    final storageExact = _storage?.lookupOpeningByEpd(normInput);
    if (storageExact != null) {
      return _entryFromStorageMap(normInput, storageExact);
    }

    // Reconcile ep-square differences only when the candidate en-passant square
    // has no legal ep capture (i.e. both EPDs represent identical chess states).
    final candidates = _byNoEpKey[_threeFieldKey(normInput)];
    if (candidates != null && candidates.isNotEmpty) {
      final inputNormalized = _epdWithOnlyLegalEp(normInput);
      for (final cand in candidates) {
        if (_epdWithOnlyLegalEp(cand.epd) == inputNormalized) {
          return cand;
        }
      }
    }

    final noEpInput = _epdWithOnlyLegalEp(normInput);
    if (noEpInput != normInput) {
      final storageStripped = _storage?.lookupOpeningByEpd(noEpInput);
      if (storageStripped != null) {
        return _entryFromStorageMap(noEpInput, storageStripped);
      }
    }

    return null;
  }

  static core.OpeningEntry _entryFromStorageMap(
    String epd,
    Map<String, dynamic> map,
  ) {
    final parsed = _splitNameAndVariation(
      (map['name'] as String?) ?? 'Opening',
      map['variation'] as String?,
    );
    return core.OpeningEntry(
      eco: (map['eco'] as String?) ?? '',
      name: parsed.name,
      variation: parsed.variation,
      epd: epd,
    );
  }

  static ({String name, String? variation}) _splitNameAndVariation(
    String fullName,
    String? explicitVariation,
  ) {
    if (explicitVariation != null && explicitVariation.isNotEmpty) {
      return (name: fullName, variation: explicitVariation);
    }
    final colonIdx = fullName.indexOf(':');
    if (colonIdx > 0 && colonIdx + 1 < fullName.length) {
      return (
        name: fullName.substring(0, colonIdx).trim(),
        variation: fullName.substring(colonIdx + 1).trim(),
      );
    }
    return (name: fullName, variation: null);
  }

  static String _threeFieldKey(String epd) {
    final parts = epd.split(RegExp(r'\s+'));
    if (parts.length >= 3) {
      return '${parts[0]} ${parts[1]} ${parts[2]}';
    }
    return epd;
  }

  static String _epdWithOnlyLegalEp(String epd) {
    final parts = epd.split(RegExp(r'\s+'));
    if (parts.length < 4 || parts[3] == '-') {
      return core.OpeningBookPort.fenToEpd(epd);
    }
    try {
      final fen = '${parts[0]} ${parts[1]} ${parts[2]} ${parts[3]} 0 1';
      final board = ch.Chess.fromFEN(fen);
      final hasEpCapture = board.generate_moves().any(
            (m) => (m.flags & ch.Chess.BITS_EP_CAPTURE) != 0,
          );
      return hasEpCapture
          ? '${parts[0]} ${parts[1]} ${parts[2]} ${parts[3]}'
          : '${parts[0]} ${parts[1]} ${parts[2]} -';
    } catch (_) {
      return FenNormalizer.normaliseFen(epd);
    }
  }
}
