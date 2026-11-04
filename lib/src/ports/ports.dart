import '../domain/chess/chess_models.dart';
import '../domain/chess/pgn_parser.dart';
import '../domain/coach/coach_contracts.dart';

/// Part 8.3: ExplanationProvider port interface (FR-02, AD-4).
/// Every AI source implements this exact interface; nothing outside an adapter depends on concrete provider types.
abstract class ExplanationProvider {
  String get id; // 'builtin', 'local:<modelId>', 'remote:<profileId>', 'template'
  ProviderCapabilities get caps;
  Future<ProviderStatus> check();
  Stream<CoachChunk> explain(CoachRequest req, {CancelToken? cancel});
  Future<void> dispose();
}

/// Part 11.2: Engine preset configuration.
class EnginePresetConfig {
  final String id; // 'fast', 'balanced', 'deep', 'fixed_test'
  final String displayName;
  final int threads;
  final int hashMb;
  final int moveTimeMs;
  final int targetDepth;
  final int defaultMultiPv;
  final int? fixedNodes;

  const EnginePresetConfig({
    required this.id,
    required this.displayName,
    required this.threads,
    required this.hashMb,
    required this.moveTimeMs,
    required this.targetDepth,
    this.defaultMultiPv = 1,
    this.fixedNodes,
  });

  static const EnginePresetConfig fast = EnginePresetConfig(
    id: 'fast',
    displayName: 'Fast (~0.15s / depth 12)',
    threads: 2,
    hashMb: 32,
    moveTimeMs: 150,
    targetDepth: 12,
    defaultMultiPv: 1,
  );

  static const EnginePresetConfig balanced = EnginePresetConfig(
    id: 'balanced',
    displayName: 'Balanced (~0.4s / depth 16)',
    threads: 4,
    hashMb: 64,
    moveTimeMs: 400,
    targetDepth: 16,
    defaultMultiPv: 1,
  );

  static const EnginePresetConfig deep = EnginePresetConfig(
    id: 'deep',
    displayName: 'Deep (~1.5s / depth 20)',
    threads: 4,
    hashMb: 256,
    moveTimeMs: 1500,
    targetDepth: 20,
    defaultMultiPv: 2,
  );

  static const EnginePresetConfig fixedTest = EnginePresetConfig(
    id: 'fixed_test',
    displayName: 'Fixed Nodes (Deterministic Test)',
    threads: 1,
    hashMb: 16,
    moveTimeMs: 50,
    targetDepth: 10,
    defaultMultiPv: 2,
    fixedNodes: 5000,
  );

  static EnginePresetConfig byId(String? id) {
    switch (id) {
      case 'fast':
        return fast;
      case 'deep':
        return deep;
      case 'fixed_test':
        return fixedTest;
      default:
        return balanced;
    }
  }
}

/// Port for Stockfish Engine Service (Part 8.1).
abstract class EngineService {
  String get engineVersion;
  bool get isThermalThrottled;
  Future<void> init();
  Future<EngineEvalEntity> evaluatePosition(
    String fen,
    EnginePresetConfig preset, {
    int multiPv = 1,
  });
  void setThermalThrottle(bool throttled);
  Future<void> dispose();
}

/// Import filter parameters (Part 10.1, 10.2, 26.2).
class ImportRequestParams {
  final String source; // 'lichess','chesscom','pgn_file','pgn_paste','zip','manual'
  final String? username;
  final int maxGames;
  final int? sinceEpochMs;
  final int? untilEpochMs;
  final String? timeClass; // 'bullet','blitz','rapid','classical'
  final bool ratedOnly;
  final SideColor? colorFilter;
  final String? rawPgnOrPath;
  final List<int>? fileBytes;
  final String? studentTag;

  const ImportRequestParams({
    required this.source,
    this.username,
    this.maxGames = 100,
    this.sinceEpochMs,
    this.untilEpochMs,
    this.timeClass,
    this.ratedOnly = false,
    this.colorFilter,
    this.rawPgnOrPath,
    this.fileBytes,
    this.studentTag,
  });
}

class ImportProgressUpdate {
  final String status; // 'queued','validating','fetching','preview','importing','paused_rate_limit','done','failed','cancelled'
  final int fetchedCount;
  final int newCount;
  final int duplicateCount;
  final int failedCount;
  final int? rateLimitRemainingSec;
  final String? errorCode;
  final String? message;
  final List<ParsedPgnGame> previewGames;

  const ImportProgressUpdate({
    required this.status,
    this.fetchedCount = 0,
    this.newCount = 0,
    this.duplicateCount = 0,
    this.failedCount = 0,
    this.rateLimitRemainingSec,
    this.errorCode,
    this.message,
    this.previewGames = const [],
  });
}

/// Port for Game Import Sources (Part 8.1).
abstract class GameSource {
  String get sourceId;
  bool get requiresOnline;
  Stream<ImportProgressUpdate> fetchGames(
    ImportRequestParams params, {
    CancelToken? cancel,
  });
}

/// Network Gateway Audit Entry (Part 15.1 & Story H-3 AC3: host, purpose, size, time; NEVER payload content).
class NetworkAuditEntry {
  final String host;
  final String purpose;
  final int sizeBytes;
  final int timestampMs;
  final bool blockedByOfflineOnly;

  const NetworkAuditEntry({
    required this.host,
    required this.purpose,
    required this.sizeBytes,
    required this.timestampMs,
    this.blockedByOfflineOnly = false,
  });
}

class GatewayResponse {
  final int statusCode;
  final String body;
  final Map<String, String> headers;

  const GatewayResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });
}

/// Port for Network Gateway Chokepoint (AD-8, FR-08, H-3).
abstract class NetworkGatewayPort {
  bool get isOfflineOnly;
  bool get isDeviceOnline;
  void setOfflineOnly(bool value);
  void setDeviceOnline(bool value);
  List<NetworkAuditEntry> get auditLogs;
  Future<GatewayResponse> get(
    Uri uri, {
    required String purpose,
    Map<String, String>? headers,
    CancelToken? cancel,
  });
  Future<GatewayResponse> post(
    Uri uri, {
    required String purpose,
    Map<String, String>? headers,
    required String body,
    CancelToken? cancel,
  });
}

/// Port for Platform Secure Storage (BR-3, FR-15).
abstract class SecureStorePort {
  Future<void> writeSecret(String refKey, String secretValue);
  Future<String?> readSecret(String refKey);
  Future<void> deleteSecret(String refKey);
  Future<void> wipeAllSecrets();
}
