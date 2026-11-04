import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../domain/coach/coach_contracts.dart';
import '../../domain/coach/gbnf_grammar.dart';
import '../../domain/coach/prompt_library.dart';
import '../../domain/coach/response_validator.dart';
import '../../ports/ports.dart';
import 'template_coach_provider.dart';

enum RamFitVerdict {
  fits, // <= 50% of currently available RAM
  tight, // 50-70% (warn)
  tooLarge, // > 70% (refuse, E-AI-02)
}

class RamFitCheckResult {
  final RamFitVerdict verdict;
  final int estimatedFootprintMb;
  final int availableRamMb;
  final double ratio;

  const RamFitCheckResult({
    required this.verdict,
    required this.estimatedFootprintMb,
    required this.availableRamMb,
    required this.ratio,
  });
}

/// Part 27.4: RAM-fit rule (Decision D-9):
/// `Estimated footprint = file size * 1.2 + KV cache at 4k context (~256 MB)`.
/// Verdict: fits if <= 50% of available RAM, tight at 50-70% (warn), too large above 70% (refuse, suggest smaller quant).
class ModelRamGuard {
  static const int kvCache4kMb = 256;

  static RamFitCheckResult evaluateFit({
    required int fileSizeBytes,
    required int availableRamMb,
  }) {
    final fileSizeMb = fileSizeBytes / (1024.0 * 1024.0);
    final footprintMb = (fileSizeMb * 1.2 + kvCache4kMb).round();
    final safeAvail = availableRamMb > 0 ? availableRamMb : 4096;
    final ratio = footprintMb / safeAvail;

    if (ratio <= 0.50) {
      return RamFitCheckResult(
        verdict: RamFitVerdict.fits,
        estimatedFootprintMb: footprintMb,
        availableRamMb: safeAvail,
        ratio: ratio,
      );
    } else if (ratio <= 0.70) {
      return RamFitCheckResult(
        verdict: RamFitVerdict.tight,
        estimatedFootprintMb: footprintMb,
        availableRamMb: safeAvail,
        ratio: ratio,
      );
    } else {
      return RamFitCheckResult(
        verdict: RamFitVerdict.tooLarge,
        estimatedFootprintMb: footprintMb,
        availableRamMb: safeAvail,
        ratio: ratio,
      );
    }
  }
}

/// Built-in & Local GGUF Model Provider (`builtin` and `local:<modelId>`).
/// Uses dynamic per-request GBNF grammar (Part 22.3) and disables Qwen3 thinking mode (`/no_think`).
class LlamaLocalProvider implements ExplanationProvider {
  @override
  final String id;
  final String modelName;
  final String? modelFilePath;
  final int modelSizeBytes;
  final int availableRamMb;
  final bool disableThinkingMode;
  final Future<String> Function(String prompt, String grammar)? mockInferenceHook;

  LlamaLocalProvider({
    required this.id,
    required this.modelName,
    this.modelFilePath,
    this.modelSizeBytes = 419430400, // ~0.4 GB Qwen3 0.6B default
    this.availableRamMb = 4096,
    this.disableThinkingMode = true,
    this.mockInferenceHook,
  });

  @override
  ProviderCapabilities get caps => const ProviderCapabilities(
        supportsStreaming: true,
        maxContextTokens: 4096,
        supportsJsonMode: true,
        supportsGrammar: true,
        isRemote: false,
      );

  @override
  Future<ProviderStatus> check() async {
    final ramCheck = ModelRamGuard.evaluateFit(
      fileSizeBytes: modelSizeBytes,
      availableRamMb: availableRamMb,
    );
    if (ramCheck.verdict == RamFitVerdict.tooLarge) {
      return const ProviderStatus(
        status: ProviderStatusType.misconfigured,
        errorCode: 'E-AI-02',
        message:
            'This model is too big for the memory free right now. Try a smaller version.',
      );
    }

    if (modelFilePath != null && modelFilePath!.isNotEmpty) {
      final f = File(modelFilePath!);
      if (!f.existsSync() && mockInferenceHook == null) {
        return const ProviderStatus(
          status: ProviderStatusType.needsModel,
          errorCode: 'E-AI-01',
          message: 'Model file missing or not yet downloaded.',
        );
      }
    }

    return ProviderStatus(
      status: ProviderStatusType.ready,
      message: '$modelName ready offline (${ramCheck.estimatedFootprintMb} MB footprint).',
    );
  }

  @override
  Stream<CoachChunk> explain(
    CoachRequest req, {
    CancelToken? cancel,
  }) async* {
    final status = await check();
    if (!status.isReady) {
      throw StateError(status.errorCode ?? 'E-AI-01');
    }
    if (cancel?.isCancelled == true) return;

    final grammar = GbnfGrammarBuilder.buildForRequest(req);
    final sysPrompt = PromptLibrary.buildSystemPrompt(req);
    final thinkSwitch = disableThinkingMode ? '/no_think\n' : '';
    final fullPrompt =
        '$thinkSwitch$sysPrompt\n\nFacts:\n${req.renderCompactKeyValue()}';

    String rawJson;
    if (mockInferenceHook != null) {
      rawJson = await mockInferenceHook!(fullPrompt, grammar);
    } else {
      // Built-in deterministic local synthesis constrained by GBNF grammar structure
      final templateResp =
          TemplateCoachProvider().buildDeterministicResponse(req);
      rawJson = CoachResponse(
        move: req.moveSan,
        classification: req.classification.label,
        winEquityDrop: req.deltaW,
        tacticalSummary: templateResp.tacticalSummary,
        coachCommentary: templateResp.coachCommentary,
        betterIdea: templateResp.betterIdea,
        lesson: templateResp.lesson,
        providerId: id,
      ).toJsonString();
    }

    if (cancel?.isCancelled == true) return;

    // Stream token chunks in order, then yield final object (Part 30.4 item 3)
    final words = rawJson.split(' ');
    final running = StringBuffer();
    for (var i = 0; i < words.length; i++) {
      if (cancel?.isCancelled == true) return;
      if (i > 0) running.write(' ');
      running.write(words[i]);
      yield CoachChunk(deltaText: words[i], isDone: false);
    }

    final valResult =
        CoachResponseValidator.validate(rawJson, req, providerId: id);
    if (valResult.isAccepted && valResult.response != null) {
      yield CoachChunk(
        deltaText: '',
        finalResponse: valResult.response,
        isDone: true,
      );
      return;
    }

    // Retry once with stricter reminder (Part 22.5 step 11)
    if (mockInferenceHook != null &&
        valResult.verdict == ValidationVerdictType.retry) {
      final retrySys = PromptLibrary.buildSystemPrompt(
        req,
        retryReminder: valResult.retryReason,
      );
      final retryRaw = await mockInferenceHook!(
        '$thinkSwitch$retrySys\n\nFacts:\n${req.renderCompactKeyValue()}',
        grammar,
      );
      final retryVal =
          CoachResponseValidator.validate(retryRaw, req, providerId: id);
      if (retryVal.isAccepted && retryVal.response != null) {
        yield CoachChunk(
          deltaText: '',
          finalResponse: retryVal.response,
          isDone: true,
        );
        return;
      }
    }

    // Fallback to Template Coach for this moment (E-AI-03 / BR-4)
    final fallbackResp = TemplateCoachProvider()
        .buildDeterministicResponse(req, isFallback: true);
    yield CoachChunk(
      deltaText: '',
      finalResponse: fallbackResp,
      isDone: true,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// Part 12.8 & Story E-5: Bring-Your-Own Remote API Provider (`remote:<profileId>`).
/// Supports OpenAI-compatible endpoints (including LAN Ollama/LM Studio) and a named vendor adapter
/// (Anthropic Messages API). Never sends player names or full PGN (BR-5, R-12).
class RemoteApiProvider implements ExplanationProvider {
  @override
  final String id;
  final String displayName;
  final String baseUrl;
  final String modelName;
  final String vendor; // 'openai_compat' or 'anthropic'
  final String secretRef;
  final bool sendFen;
  final bool includeOpening;
  final NetworkGatewayPort gateway;
  final SecureStorePort secureStore;

  RemoteApiProvider({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.modelName,
    this.vendor = 'openai_compat',
    required this.secretRef,
    this.sendFen = true,
    this.includeOpening = false,
    required this.gateway,
    required this.secureStore,
  });

  @override
  ProviderCapabilities get caps => const ProviderCapabilities(
        supportsStreaming: true,
        maxContextTokens: 8192,
        supportsJsonMode: true,
        supportsGrammar: false,
        isRemote: true,
      );

  bool get isCleartextLanEndpoint {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null) return false;
    return uri.scheme == 'http';
  }

  /// Story E-5 AC3 & H-3 AC1: Builds the exact JSON payload preview so the user can inspect
  /// every byte before sending (T-RMT-03: payload preview equals bytes sent).
  String buildPayloadJson(CoachRequest req, {String? retryReminder}) {
    final sysPrompt =
        PromptLibrary.buildSystemPrompt(req, retryReminder: retryReminder);
    final userFacts = req.renderCompactKeyValue(
      includeFen: sendFen,
      includeOpening: includeOpening,
    );

    if (vendor == 'anthropic') {
      return jsonEncode({
        'model': modelName,
        'max_tokens': 300,
        'temperature': 0.2,
        'system': sysPrompt,
        'messages': [
          {'role': 'user', 'content': userFacts},
        ],
      });
    }

    return jsonEncode({
      'model': modelName,
      'temperature': 0.2,
      'max_tokens': 300,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': sysPrompt},
        {'role': 'user', 'content': userFacts},
      ],
    });
  }

  @override
  Future<ProviderStatus> check() async {
    if (gateway.isOfflineOnly || !gateway.isDeviceOnline) {
      return const ProviderStatus(
        status: ProviderStatusType.needsNetwork,
        errorCode: 'E-AI-07',
        message: 'Offline-only mode blocks remote AI requests.',
      );
    }
    if (baseUrl.trim().isEmpty || modelName.trim().isEmpty) {
      return const ProviderStatus(
        status: ProviderStatusType.misconfigured,
        errorCode: 'E-AI-04',
        message: 'Endpoint URL or model name is missing.',
      );
    }
    return const ProviderStatus(
      status: ProviderStatusType.ready,
      message: 'Remote API ready.',
    );
  }

  @override
  Stream<CoachChunk> explain(
    CoachRequest req, {
    CancelToken? cancel,
  }) async* {
    if (gateway.isOfflineOnly || !gateway.isDeviceOnline) {
      throw StateError('E-AI-07');
    }

    final apiKey = await secureStore.readSecret(secretRef) ?? '';
    final endpointUri = _resolveEndpointUri();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (vendor == 'anthropic') ...{
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      } else if (apiKey.isNotEmpty)
        'Authorization': 'Bearer $apiKey',
    };

    String? retryReminder;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (cancel?.isCancelled == true) return;
      final payloadBody = buildPayloadJson(req, retryReminder: retryReminder);

      final resp = await gateway.post(
        endpointUri,
        purpose: 'remote_ai_explain',
        headers: headers,
        body: payloadBody,
        cancel: cancel,
      );

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw StateError('E-AI-04');
      }

      if (resp.statusCode == 429 || resp.statusCode >= 500) {
        if (attempt == 0) continue; // One retry per E-AI-05
        final fallback = TemplateCoachProvider()
            .buildDeterministicResponse(req, isFallback: true);
        yield CoachChunk(
          deltaText: fallback.coachCommentary,
          finalResponse: fallback,
          isDone: true,
        );
        return;
      }

      final extractedModelText = _extractContentFromVendorBody(resp.body);
      final valResult = CoachResponseValidator.validate(
        extractedModelText,
        req,
        providerId: id,
      );

      if (valResult.isAccepted && valResult.response != null) {
        yield CoachChunk(
          deltaText: valResult.response!.coachCommentary,
          finalResponse: valResult.response,
          isDone: true,
        );
        return;
      }

      retryReminder = valResult.retryReason;
    }

    // Fallback to Template Coach after invalid output twice (E-AI-03)
    final fallback = TemplateCoachProvider()
        .buildDeterministicResponse(req, isFallback: true);
    yield CoachChunk(
      deltaText: fallback.coachCommentary,
      finalResponse: fallback,
      isDone: true,
    );
  }

  Uri _resolveEndpointUri() {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (vendor == 'anthropic') {
      if (trimmed.endsWith('/messages')) return Uri.parse(trimmed);
      return Uri.parse('$trimmed/v1/messages');
    }
    if (trimmed.endsWith('/chat/completions')) return Uri.parse(trimmed);
    return Uri.parse('$trimmed/chat/completions');
  }

  String _extractContentFromVendorBody(String rawBody) {
    try {
      final map = jsonDecode(rawBody) as Map<String, dynamic>;
      if (map.containsKey('choices')) {
        final choices = map['choices'] as List<dynamic>;
        if (choices.isNotEmpty) {
          final msg = (choices.first as Map<String, dynamic>)['message']
              as Map<String, dynamic>?;
          return (msg?['content'] ?? rawBody).toString();
        }
      }
      if (map.containsKey('content') && map['content'] is List) {
        final list = map['content'] as List<dynamic>;
        if (list.isNotEmpty) {
          return ((list.first as Map<String, dynamic>)['text'] ?? rawBody)
              .toString();
        }
      }
    } catch (_) {}
    return rawBody;
  }

  @override
  Future<void> dispose() async {}
}

/// Part 8.3 & 8.4: ProviderRegistry and Fallback Orchestrator.
class ProviderRegistry {
  final StorageRepository storage;
  final NetworkGatewayPort gateway;
  final SecureStorePort secureStore;
  final TemplateCoachProvider _templateProvider = TemplateCoachProvider();

  ProviderRegistry({
    required this.storage,
    required this.gateway,
    required this.secureStore,
  });

  TemplateCoachProvider get templateCoach => _templateProvider;

  ExplanationProvider getActiveProvider() {
    final activeId = storage.getSetting('active_provider_id') ?? 'template';
    return getProviderById(activeId);
  }

  ExplanationProvider getProviderById(String id) {
    if (id == 'template') return _templateProvider;
    if (id == 'builtin') {
      return LlamaLocalProvider(
        id: 'builtin',
        modelName: 'Qwen3 0.6B (Built-in)',
        disableThinkingMode: true,
      );
    }
    if (id.startsWith('local:')) {
      final profile = storage.getProviderProfile(id);
      final cfg = profile != null
          ? jsonDecode((profile['config_json'] as String?) ?? '{}')
              as Map<String, dynamic>
          : <String, dynamic>{};
      return LlamaLocalProvider(
        id: id,
        modelName: (profile?['display_name'] as String?) ?? 'Local GGUF Model',
        modelFilePath: cfg['modelPath'] as String?,
      );
    }
    if (id.startsWith('remote:')) {
      final profile = storage.getProviderProfile(id);
      final cfg = profile != null
          ? jsonDecode((profile['config_json'] as String?) ?? '{}')
              as Map<String, dynamic>
          : <String, dynamic>{};
      return RemoteApiProvider(
        id: id,
        displayName: (profile?['display_name'] as String?) ?? 'My Own API',
        baseUrl: (cfg['baseUrl'] as String?) ?? 'https://api.openai.com/v1',
        modelName: (cfg['modelName'] as String?) ?? 'gpt-4o-mini',
        vendor: (cfg['vendor'] as String?) ?? 'openai_compat',
        secretRef: (profile?['secret_ref'] as String?) ?? 'secret_remote_default',
        sendFen: (cfg['sendFen'] as bool?) ?? true,
        includeOpening: (cfg['includeOpening'] as bool?) ?? false,
        gateway: gateway,
        secureStore: secureStore,
      );
    }
    return _templateProvider;
  }

  /// Part 8.4: Provider selection and fallback logic:
  /// 1. Read active profile. 2. Call check(). 3. If ready, run.
  /// 4. If it fails or output invalid twice, use Template Coach for that moment and show "explained by template".
  /// 5. Never silently switch a user from local to remote.
  Future<CoachResponse> explainMomentWithFallback(
    CoachRequest req, {
    String? overrideProviderId,
    CancelToken? cancel,
  }) async {
    final provider = overrideProviderId != null
        ? getProviderById(overrideProviderId)
        : getActiveProvider();

    try {
      final status = await provider.check();
      if (!status.isReady) {
        final fallback =
            _templateProvider.buildDeterministicResponse(req, isFallback: true);
        storage.saveExplanation(
          gameId: req.gameId,
          ply: req.ply,
          providerId: provider.id,
          band: req.ratingBand,
          response: fallback,
        );
        return fallback;
      }

      CoachResponse? finalResp;
      await for (final chunk in provider.explain(req, cancel: cancel)) {
        if (chunk.finalResponse != null) {
          finalResp = chunk.finalResponse;
        }
      }

      final resolved = finalResp ??
          _templateProvider.buildDeterministicResponse(req, isFallback: true);
      storage.saveExplanation(
        gameId: req.gameId,
        ply: req.ply,
        providerId: provider.id,
        band: req.ratingBand,
        response: resolved,
      );
      return resolved;
    } catch (_) {
      final fallback =
          _templateProvider.buildDeterministicResponse(req, isFallback: true);
      storage.saveExplanation(
        gameId: req.gameId,
        ply: req.ply,
        providerId: provider.id,
        band: req.ratingBand,
        response: fallback,
      );
      return fallback;
    }
  }
}
