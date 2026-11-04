import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../adapters/engine/stockfish_engine_adapter.dart';
import '../adapters/network/network_gateway_adapter.dart';
import '../adapters/providers/llama_and_remote_providers.dart';
import '../adapters/sources/game_sources_adapter.dart';
import '../adapters/storage/sqlite_storage_adapter.dart';
import '../domain/chess/chess_models.dart';
import '../domain/chess/pgn_parser.dart';
import '../ports/ports.dart';
import 'analysis_pipeline_service.dart';
import 'export_service.dart';

class AppServices {
  final StorageRepository storage;
  final NetworkGatewayAdapter gateway;
  final SecureStoreAdapter secureStore;
  final StockfishEngineAdapter engine;
  final ProviderRegistry providerRegistry;
  final AnalysisPipelineService pipeline;
  final ExportService exportService;
  final LichessGameSource lichessSource;
  final ChessComGameSource chessComSource;
  final OfflinePgnGameSource pgnSource;

  AppServices({
    required this.storage,
    required this.gateway,
    required this.secureStore,
    required this.engine,
    required this.providerRegistry,
    required this.pipeline,
    required this.exportService,
    required this.lichessSource,
    required this.chessComSource,
    required this.pgnSource,
  });

  factory AppServices.createDefault({bool seedDemoGame = true}) {
    final storage = StorageRepository();
    final gateway = NetworkGatewayAdapter(initialOfflineOnly: true);
    final secureStore = SecureStoreAdapter(useMemoryOnly: true);
    final engine = StockfishEngineAdapter();
    final registry = ProviderRegistry(
      storage: storage,
      gateway: gateway,
      secureStore: secureStore,
    );
    final pipeline = AnalysisPipelineService(
      storage: storage,
      engine: engine,
      providerRegistry: registry,
    );
    final exportService = ExportService(
      storage: storage,
      engine: engine,
      gateway: gateway,
    );
    final lichess = LichessGameSource(gateway: gateway);
    final chessCom = ChessComGameSource(gateway: gateway);
    final pgnSource = OfflinePgnGameSource();

    if (seedDemoGame) {
      const samplePgn = '''
[Event "Club Rapid Championship"]
[Site "Offline OTB"]
[Date "2026.11.01"]
[Round "1"]
[White "PlayerOne"]
[Black "ClubOpponent"]
[Result "1-0"]
[WhiteElo "1420"]
[BlackElo "1395"]
[ECO "C50"]
[Opening "Italian Game: Giuoco Piano"]
[TimeControl "600+0"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6 5. d4 exd4 6. cxd4 Bb4+ 7. Nc3 Nxe4 8. O-O Nxc3 9. bxc3 Bxc3 10. Qb3 Bxa1 11. Bxf7+ Kf8 12. Bg5 Ne7 13. Ne5 Bxd4 14. Bg6 d5 15. Qf3+ Bf5 16. Bxf5 Bxe5 17. Be6+ Bf6 18. Bxf6 gxf6 19. Qxf6+ Ke8 20. Qf7# 1-0
''';
      final report = PgnParser.parseMultiGamePgn(samplePgn, source: 'pgn');
      for (final g in report.games) {
        storage.upsertParsedGame(g);
      }
    }

    return AppServices(
      storage: storage,
      gateway: gateway,
      secureStore: secureStore,
      engine: engine,
      providerRegistry: registry,
      pipeline: pipeline,
      exportService: exportService,
      lichessSource: lichess,
      chessComSource: chessCom,
      pgnSource: pgnSource,
    );
  }
}

final appServicesProvider = Provider<AppServices>((ref) {
  return AppServices.createDefault();
});

class AppUiState {
  final bool onboardingDone;
  final RatingBand ratingBand;
  final String activeProviderId;
  final bool offlineOnly;
  final bool deviceOnline;
  final String enginePresetId;
  final String classificationPresetId;
  final ThemeMode themeMode;
  final List<GameEntity> games;
  final String? selectedGameId;
  final bool reviewBothSides;
  final int revision;

  const AppUiState({
    required this.onboardingDone,
    required this.ratingBand,
    required this.activeProviderId,
    required this.offlineOnly,
    required this.deviceOnline,
    required this.enginePresetId,
    required this.classificationPresetId,
    required this.themeMode,
    required this.games,
    this.selectedGameId,
    this.reviewBothSides = false,
    this.revision = 0,
  });

  AppUiState copyWith({
    bool? onboardingDone,
    RatingBand? ratingBand,
    String? activeProviderId,
    bool? offlineOnly,
    bool? deviceOnline,
    String? enginePresetId,
    String? classificationPresetId,
    ThemeMode? themeMode,
    List<GameEntity>? games,
    String? selectedGameId,
    bool? reviewBothSides,
    int? revision,
  }) {
    return AppUiState(
      onboardingDone: onboardingDone ?? this.onboardingDone,
      ratingBand: ratingBand ?? this.ratingBand,
      activeProviderId: activeProviderId ?? this.activeProviderId,
      offlineOnly: offlineOnly ?? this.offlineOnly,
      deviceOnline: deviceOnline ?? this.deviceOnline,
      enginePresetId: enginePresetId ?? this.enginePresetId,
      classificationPresetId:
          classificationPresetId ?? this.classificationPresetId,
      themeMode: themeMode ?? this.themeMode,
      games: games ?? this.games,
      selectedGameId: selectedGameId ?? this.selectedGameId,
      reviewBothSides: reviewBothSides ?? this.reviewBothSides,
      revision: revision ?? (this.revision + 1),
    );
  }
}

class AppUiNotifier extends StateNotifier<AppUiState> {
  final AppServices services;

  AppUiNotifier(this.services)
      : super(
          AppUiState(
            onboardingDone:
                services.storage.getSetting('onboarding_done') == 'true',
            ratingBand: RatingBand.fromLabel(
              services.storage.getSetting('rating_band'),
            ),
            activeProviderId:
                services.storage.getSetting('active_provider_id') ?? 'template',
            offlineOnly:
                services.storage.getSetting('offline_only') != 'false',
            deviceOnline: services.gateway.isDeviceOnline,
            enginePresetId:
                services.storage.getSetting('engine_preset_id') ?? 'balanced',
            classificationPresetId:
                services.storage.getSetting('classification_preset_id') ??
                    'lichess',
            themeMode: ThemeMode.system,
            games: services.storage.listGames(),
            selectedGameId: services.storage.listGames().firstOrNull?.id,
          ),
        );

  void completeOnboarding({
    required RatingBand band,
    required String providerId,
    required bool offlineOnly,
  }) {
    services.storage.setSetting('rating_band', band.label);
    services.storage.setSetting('active_provider_id', providerId);
    services.storage.setSetting('offline_only', offlineOnly.toString());
    services.storage.setSetting('onboarding_done', 'true');
    services.gateway.setOfflineOnly(offlineOnly);
    state = state.copyWith(
      onboardingDone: true,
      ratingBand: band,
      activeProviderId: providerId,
      offlineOnly: offlineOnly,
      games: services.storage.listGames(),
    );
  }

  void setOfflineOnly(bool value) {
    services.storage.setSetting('offline_only', value.toString());
    services.gateway.setOfflineOnly(value);
    state = state.copyWith(
      offlineOnly: value,
      deviceOnline: services.gateway.isDeviceOnline,
    );
  }

  void setRatingBand(RatingBand band) {
    // Story A-1 AC3: Changing band does not rewrite old explanations
    services.storage.setSetting('rating_band', band.label);
    state = state.copyWith(ratingBand: band);
  }

  void setActiveProvider(String providerId) {
    // Story A-2 AC3: Takes effect for the next explanation without restarting
    services.storage.setSetting('active_provider_id', providerId);
    state = state.copyWith(activeProviderId: providerId);
  }

  void setEnginePreset(String presetId) {
    services.storage.setSetting('engine_preset_id', presetId);
    state = state.copyWith(enginePresetId: presetId);
  }

  void setClassificationPreset(String presetId) {
    services.storage.setSetting('classification_preset_id', presetId);
    state = state.copyWith(classificationPresetId: presetId);
  }

  void setThemeMode(ThemeMode mode) {
    state = state.copyWith(themeMode: mode);
  }

  void setReviewBothSides(bool both) {
    state = state.copyWith(reviewBothSides: both);
  }

  void selectGame(String gameId) {
    state = state.copyWith(selectedGameId: gameId);
  }

  void refreshGames({
    String? searchQuery,
    String? sourceFilter,
    SideColor? colorFilter,
    String? timeClassFilter,
    bool? analysedOnly,
  }) {
    final list = services.storage.listGames(
      searchQuery: searchQuery,
      sourceFilter: sourceFilter,
      colorFilter: colorFilter,
      timeClassFilter: timeClassFilter,
      analysedOnly: analysedOnly,
    );
    state = state.copyWith(
      games: list,
      selectedGameId: state.selectedGameId ?? list.firstOrNull?.id,
    );
  }

  void deleteGame(String gameId) {
    services.storage.deleteGame(gameId);
    refreshGames();
  }

  void wipeAll({bool keepModels = true}) {
    services.storage.wipeAllData(keepModels: keepModels);
    services.secureStore.wipeAllSecrets();
    state = state.copyWith(
      onboardingDone: false,
      games: const [],
      selectedGameId: null,
    );
  }
}

final appUiProvider = StateNotifierProvider<AppUiNotifier, AppUiState>((ref) {
  final services = ref.watch(appServicesProvider);
  return AppUiNotifier(services);
});
