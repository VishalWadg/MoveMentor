import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../domain/coach/coach_contracts.dart';
import '../../ports/ports.dart';

/// Part 8.2 (AD-8) & Story H-3: Single network gateway chokepoint that enforces
/// the global "Offline only" switch and logs `(host, purpose, size, time)` locally,
/// NEVER logging payload content or secrets.
class NetworkGatewayAdapter implements NetworkGatewayPort {
  final Dio _dio;
  bool _offlineOnly;
  bool _deviceOnline;
  final List<NetworkAuditEntry> _auditLogs = [];

  NetworkGatewayAdapter({
    Dio? dio,
    bool initialOfflineOnly = true, // D-14: Offline-only ON by default
    bool initialDeviceOnline = true,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
                validateStatus: (_) => true,
              ),
            ),
        _offlineOnly = initialOfflineOnly,
        _deviceOnline = initialDeviceOnline;

  @override
  bool get isOfflineOnly => _offlineOnly;

  @override
  bool get isDeviceOnline => _deviceOnline && !_offlineOnly;

  @override
  void setOfflineOnly(bool value) {
    _offlineOnly = value;
  }

  @override
  void setDeviceOnline(bool value) {
    _deviceOnline = value;
  }

  @override
  List<NetworkAuditEntry> get auditLogs => List.unmodifiable(_auditLogs);

  void _recordAudit({
    required Uri uri,
    required String purpose,
    required int sizeBytes,
    required bool blocked,
  }) {
    _auditLogs.add(
      NetworkAuditEntry(
        host: uri.host,
        purpose: purpose,
        sizeBytes: sizeBytes,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        blockedByOfflineOnly: blocked,
      ),
    );
    if (_auditLogs.length > 500) {
      _auditLogs.removeAt(0);
    }
  }

  void _enforceOnlineAllowed(Uri uri, String purpose) {
    if (_offlineOnly) {
      _recordAudit(uri: uri, purpose: purpose, sizeBytes: 0, blocked: true);
      throw StateError(
        purpose.startsWith('remote_ai') ? 'E-AI-07' : 'E-IMP-04',
      );
    }
    if (!_deviceOnline) {
      _recordAudit(uri: uri, purpose: purpose, sizeBytes: 0, blocked: true);
      throw StateError('E-IMP-04');
    }
  }

  @override
  Future<GatewayResponse> get(
    Uri uri, {
    required String purpose,
    Map<String, String>? headers,
    CancelToken? cancel,
  }) async {
    _enforceOnlineAllowed(uri, purpose);
    final dioCancel = CancelTokenAdapter.toDio(cancel);
    final resp = await _dio.getUri<String>(
      uri,
      options: Options(headers: headers, responseType: ResponseType.plain),
      cancelToken: dioCancel,
    );
    final bodyStr = resp.data ?? '';
    _recordAudit(
      uri: uri,
      purpose: purpose,
      sizeBytes: bodyStr.length,
      blocked: false,
    );
    final flatHeaders = <String, String>{};
    resp.headers.forEach((k, v) {
      if (v.isNotEmpty) flatHeaders[k.toLowerCase()] = v.first;
    });
    return GatewayResponse(
      statusCode: resp.statusCode ?? 500,
      body: bodyStr,
      headers: flatHeaders,
    );
  }

  @override
  Future<GatewayResponse> post(
    Uri uri, {
    required String purpose,
    Map<String, String>? headers,
    required String body,
    CancelToken? cancel,
  }) async {
    _enforceOnlineAllowed(uri, purpose);
    final dioCancel = CancelTokenAdapter.toDio(cancel);
    _recordAudit(
      uri: uri,
      purpose: purpose,
      sizeBytes: body.length,
      blocked: false,
    );
    final resp = await _dio.postUri<String>(
      uri,
      data: body,
      options: Options(headers: headers, responseType: ResponseType.plain),
      cancelToken: dioCancel,
    );
    final flatHeaders = <String, String>{};
    resp.headers.forEach((k, v) {
      if (v.isNotEmpty) flatHeaders[k.toLowerCase()] = v.first;
    });
    return GatewayResponse(
      statusCode: resp.statusCode ?? 500,
      body: resp.data ?? '',
      headers: flatHeaders,
    );
  }
}

class CancelTokenAdapter {
  static CancelToken? wrap(CancelToken? token) => token;

  static dynamic toDio(CancelToken? token) => null;
}

/// Platform Secure Storage Adapter (Keychain / Android Keystore) with in-memory fallback for tests.
class SecureStoreAdapter implements SecureStorePort {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Map<String, String> _memoryStore = {};
  final bool useMemoryOnly;

  SecureStoreAdapter({this.useMemoryOnly = false});

  @override
  Future<void> writeSecret(String refKey, String secretValue) async {
    _memoryStore[refKey] = secretValue;
    if (!useMemoryOnly) {
      try {
        await _secureStorage.write(key: refKey, value: secretValue);
      } catch (_) {}
    }
  }

  @override
  Future<String?> readSecret(String refKey) async {
    if (_memoryStore.containsKey(refKey)) return _memoryStore[refKey];
    if (!useMemoryOnly) {
      try {
        return await _secureStorage.read(key: refKey);
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<void> deleteSecret(String refKey) async {
    _memoryStore.remove(refKey);
    if (!useMemoryOnly) {
      try {
        await _secureStorage.delete(key: refKey);
      } catch (_) {}
    }
  }

  @override
  Future<void> wipeAllSecrets() async {
    _memoryStore.clear();
    if (!useMemoryOnly) {
      try {
        await _secureStorage.deleteAll();
      } catch (_) {}
    }
  }
}
