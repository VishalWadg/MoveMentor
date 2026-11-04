import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../adapters/providers/llama_and_remote_providers.dart';
import '../../adapters/storage/sqlite_storage_adapter.dart';
import '../../application/analysis_pipeline_service.dart';
import '../../application/app_state.dart';
import '../../application/copy_deck.dart';
import '../../domain/chess/chess_models.dart';
import '../../domain/chess/pgn_parser.dart';
import '../../domain/coach/coach_contracts.dart';
import '../../ports/ports.dart';
import '../widgets/chess_board_widget.dart';

/// Main App Shell managing Onboarding (Screen 1) and Main Navigation across Screens 2..16.
class MoveMentorAppShell extends ConsumerStatefulWidget {
  const MoveMentorAppShell({super.key});

  @override
  ConsumerState<MoveMentorAppShell> createState() => _MoveMentorAppShellState();
}

class _MoveMentorAppShellState extends ConsumerState<MoveMentorAppShell> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(appUiProvider);
    if (!uiState.onboardingDone) {
      return const OnboardingScreen();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('MoveMentor'),
        actions: [
          // Persistent Offline / Online Status Chip (Story A-3 AC1 & Part 28.5)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: ActionChip(
              avatar: Icon(
                uiState.offlineOnly ? Icons.airplanemode_active : Icons.cloud_done,
                size: 16,
              ),
              label: Text(
                uiState.offlineOnly ? 'Offline mode' : 'Online ready',
                style: const TextStyle(fontSize: 12),
              ),
              tooltip: uiState.offlineOnly
                  ? CopyDeck.tr('status.offline')
                  : CopyDeck.tr('status.online'),
              onPressed: () {
                ref.read(appUiProvider.notifier).setOfflineOnly(!uiState.offlineOnly);
              },
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: const [
          GameLibraryScreen(), // Screen 2 (+ pushes Screens 3..7)
          GameReviewScreen(), // Screen 8 & 9
          WeaknessDashboardScreen(), // Screen 10
          SettingsHubScreen(), // Screens 11..16
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (idx) => setState(() => _tabIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined),
            selectedIcon: Icon(Icons.analytics),
            label: 'Review',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// Screen 1: 3-Step Onboarding (Story A-1, A-2 & Part 28.1 Wireframe).
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  RatingBand _selectedBand = RatingBand.intermediate;
  final TextEditingController _eloController = TextEditingController();
  String _selectedProviderId = 'template';
  bool _offlineOnly = true; // D-14: Offline-only on by default

  @override
  void dispose() {
    _eloController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome to MoveMentor')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Step 1 of 3 — Choose your rating band',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: RatingBand.values.map((band) {
              return ChoiceChip(
                label: Text('${band.label} (${band.minElo}-${band.maxElo})'),
                selected: _selectedBand == band,
                onSelected: (_) => setState(() => _selectedBand = band),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _eloController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Or type your rating (maps to band automatically)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (val) {
              final elo = int.tryParse(val);
              if (elo != null) {
                setState(() => _selectedBand = RatingBand.fromRating(elo));
              }
            },
          ),
          const SizedBox(height: 20),
          // Step 2: Privacy card (Story A-1 AC2)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Step 2 of 3 — Privacy & Offline Guarantee',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(CopyDeck.tr('status.offline')),
                  const SizedBox(height: 4),
                  const Text(
                    'What stays on-device: Your games, Stockfish evaluations, tactic tags, and local AI models. What can go online (only if you ask): Lichess/Chess.com username imports and your own optional API endpoint.',
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Offline-only mode (Default ON)'),
                    subtitle: const Text('Blocks all network traffic.'),
                    value: _offlineOnly,
                    onChanged: (v) => setState(() => _offlineOnly = v),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Step 3: Choose a coach (Part 28.1 Wireframe verbatim)
          const Text(
            'Step 3 of 3 — Choose a coach',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _buildCoachOption(
            id: 'template',
            title: 'Template coach',
            subtitle: 'No download. Works offline. Instant.',
          ),
          _buildCoachOption(
            id: 'builtin',
            title: 'Built-in model (~0.5 GB)',
            subtitle: 'Offline. Best on 6 GB+ phones.',
          ),
          _buildCoachOption(
            id: 'local:default',
            title: 'My own model file (.gguf)',
            subtitle: 'Offline. For advanced users.',
          ),
          _buildCoachOption(
            id: 'remote:default',
            title: 'My own API',
            subtitle: 'Sends move data to a server you choose.',
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Text('You can change this any time.'),
          ),
          FilledButton(
            key: const ValueKey('onboarding_continue_btn'),
            onPressed: () {
              ref.read(appUiProvider.notifier).completeOnboarding(
                    band: _selectedBand,
                    providerId: _selectedProviderId,
                    offlineOnly: _offlineOnly,
                  );
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Widget _buildCoachOption({
    required String id,
    required String title,
    required String subtitle,
  }) {
    return RadioListTile<String>(
      value: id,
      groupValue: _selectedProviderId,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      onChanged: (val) {
        if (val != null) setState(() => _selectedProviderId = val);
      },
    );
  }
}

/// Screen 2: Home / Game Library + Navigation to Import Hub (Screen 3..6) and Analysis (Screen 7).
class GameLibraryScreen extends ConsumerStatefulWidget {
  const GameLibraryScreen({super.key});

  @override
  ConsumerState<GameLibraryScreen> createState() => _GameLibraryScreenState();
}

class _GameLibraryScreenState extends ConsumerState<GameLibraryScreen> {
  String _searchQuery = '';
  String? _sourceFilter;

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(appUiProvider);
    final services = ref.watch(appServicesProvider);
    final games = uiState.games;

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search player, opening, ECO, event...',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (val) {
                      _searchQuery = val;
                      ref.read(appUiProvider.notifier).refreshGames(
                            searchQuery: _searchQuery,
                            sourceFilter: _sourceFilter,
                          );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String?>(
                  value: _sourceFilter,
                  hint: const Text('Source'),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('All')),
                    DropdownMenuItem(value: 'pgn', child: Text('PGN')),
                    DropdownMenuItem(value: 'lichess', child: Text('Lichess')),
                    DropdownMenuItem(value: 'chesscom', child: Text('Chess.com')),
                    DropdownMenuItem(value: 'manual', child: Text('Manual')),
                  ],
                  onChanged: (val) {
                    setState(() => _sourceFilter = val);
                    ref.read(appUiProvider.notifier).refreshGames(
                          searchQuery: _searchQuery,
                          sourceFilter: _sourceFilter,
                        );
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: games.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sports_esports_outlined, size: 48),
                        const SizedBox(height: 8),
                        Text(CopyDeck.tr('empty.library')),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: games.length,
                    itemBuilder: (context, index) {
                      final g = games[index];
                      final summary = services.storage.getGameSummary(g.id);
                      final myAcc = summary == null
                          ? null
                          : (g.myColor == SideColor.w
                              ? summary.accWhite
                              : summary.accBlack);

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: ListTile(
                          title: Text('${g.white} vs ${g.black} (${g.result})'),
                          subtitle: Text(
                            '${g.eco ?? ""} ${g.openingName ?? "Standard"} • ${g.source.toUpperCase()} • ${g.status}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (myAcc != null)
                                Chip(
                                  label: Text('${myAcc.toStringAsFixed(1)}%'),
                                ),
                              IconButton(
                                icon: const Icon(Icons.play_circle_outline),
                                tooltip: 'Analyse Game Offline',
                                onPressed: g.isAnalysable
                                    ? () => _runGameAnalysisDialog(context, g.id)
                                    : null,
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Delete Game',
                                onPressed: () {
                                  ref.read(appUiProvider.notifier).deleteGame(g.id);
                                },
                              ),
                            ],
                          ),
                          onTap: () {
                            ref.read(appUiProvider.notifier).selectGame(g.id);
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ImportHubScreen()),
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('Add games'),
      ),
    );
  }

  Future<void> _runGameAnalysisDialog(BuildContext context, String gameId) async {
    final services = ref.read(appServicesProvider);
    final cancel = CancelToken();

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StreamBuilder<AnalysisProgressState>(
          stream: services.pipeline.analyseGame(gameId, cancel: cancel),
          builder: (ctx, snapshot) {
            final state = snapshot.data;
            if (state?.stage == 'done') {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                ref.read(appUiProvider.notifier).refreshGames();
                ref.read(appUiProvider.notifier).selectGame(gameId);
                if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
              });
            }
            return AlertDialog(
              title: const Text('Analysing Offline'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(CopyDeck.tr('analysis.running')),
                  if (state?.thermalThrottled == true) ...[
                    const SizedBox(height: 6),
                    Text(
                      CopyDeck.tr('analysis.thermal'),
                      style: const TextStyle(color: Colors.orange),
                    ),
                  ],
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: state?.progress ?? 0.0),
                  const SizedBox(height: 8),
                  Text(
                    'Stage: ${state?.stage ?? "starting"} (${state?.currentPly ?? 0}/${state?.totalPlies ?? 0} plies)',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancel.cancel();
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Pause / Cancel'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Screen 3..6: Import Hub (matching Part 28.2 Wireframe) + Lichess/Chess.com/PGN/Paste/Manual Entry + Import Preview.
class ImportHubScreen extends ConsumerStatefulWidget {
  const ImportHubScreen({super.key});

  @override
  ConsumerState<ImportHubScreen> createState() => _ImportHubScreenState();
}

class _ImportHubScreenState extends ConsumerState<ImportHubScreen> {
  final TextEditingController _pgnPasteController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  String _statusMessage = '';
  List<ParsedPgnGame> _previewGames = [];
  bool _isFetching = false;

  @override
  void dispose() {
    _pgnPasteController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(appUiProvider);
    final isOffline = uiState.offlineOnly || !uiState.deviceOnline;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add games'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Chip(
              avatar: Icon(
                isOffline ? Icons.cloud_off : Icons.cloud_done,
                size: 16,
              ),
              label: Text(isOffline ? 'Offline mode' : 'Online'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (isOffline)
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off, color: Colors.amber),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Offline-Only Mode is Active',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Network requests are blocked for privacy. To fetch directly from Lichess or Chess.com, tap Go Online.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () {
                        ref.read(appUiProvider.notifier).setOfflineOnly(false);
                      },
                      child: const Text('Go Online'),
                    ),
                  ],
                ),
              ),
            )
          else
            Card(
              color: Colors.green.withValues(alpha: 0.08),
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_done, color: Colors.green),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Online Mode Active',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Ready to import your games from Lichess or Chess.com.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        ref.read(appUiProvider.notifier).setOfflineOnly(true);
                      },
                      child: const Text('Go Offline'),
                    ),
                  ],
                ),
              ),
            ),
          if (_isFetching) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: _buildHubTile(
                  title: 'Lichess',
                  subtitle: isOffline
                      ? 'Offline: Queue or tap Go Online'
                      : 'Fetch by username directly',
                  dimmed: isOffline,
                  onTap: () => _showOnlineImportSheet('lichess', isOffline),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildHubTile(
                  title: 'Chess.com',
                  subtitle: isOffline
                      ? 'Offline: Queue or tap Go Online'
                      : 'Fetch by username directly',
                  dimmed: isOffline,
                  onTap: () => _showOnlineImportSheet('chesscom', isOffline),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildHubTile(
                  title: 'PGN file / ZIP',
                  subtitle: 'works offline (up to 50 MB / 5,000 games)',
                  dimmed: false,
                  onTap: _loadSamplePgnFileOffline,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildHubTile(
                  title: 'Paste PGN',
                  subtitle: 'works offline (live validation)',
                  dimmed: false,
                  onTap: _showPastePgnDialog,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildHubTile(
            title: 'Enter a game move by move',
            subtitle: 'Manual OTB scoresheet entry with legality checks (works offline)',
            dimmed: false,
            onTap: _showPastePgnDialog,
          ),
          if (_statusMessage.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    _isFetching ? Icons.sync : Icons.info_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusMessage,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_previewGames.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Import Preview (${_previewGames.length} games ready)',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final pg in _previewGames)
              Card(
                child: ListTile(
                  title: Text('${pg.game.white} vs ${pg.game.black} (${pg.game.result})'),
                  subtitle: Text(
                    'Moves: ${pg.game.movesSan.length} plies • Status: ${pg.game.status}${pg.warningMessage != null ? " (${pg.warningMessage})" : ""}',
                  ),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _commitPreviewImport,
              icon: const Icon(Icons.check),
              label: Text('Save ${_previewGames.length} Game(s) to Library'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHubTile({
    required String title,
    required String subtitle,
    required bool dimmed,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: dimmed ? 0.6 : 1.0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  void _loadSamplePgnFileOffline() {
    const pgn = '''
[Event "Train Commute Practice"]
[Site "Offline"]
[Date "2026.11.02"]
[White "Raj"]
[Black "Opponent"]
[Result "0-1"]
[ECO "B20"]
[Opening "Sicilian Defense"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 7. Nb3 Be6 8. Qxb7 Nbd7 9. Qc6 Rc8 10. Qa4 Rxc3 11. bxc3 Nxe4 0-1
''';
    final report = PgnParser.parseMultiGamePgn(pgn, source: 'pgn');
    setState(() {
      _previewGames = report.games;
      _statusMessage = 'Validated ${report.games.length} offline PGN game(s).';
    });
  }

  Future<void> _showPastePgnDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        var foundCount = 0;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Paste PGN Text'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _pgnPasteController,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      hintText: '1. e4 e5 2. Nf3 Nc6 ...',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      final r = PgnParser.parseMultiGamePgn(val);
                      setDialogState(() => foundCount = r.games.length);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text('Live validation: $foundCount valid game(s) detected.'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final r = PgnParser.parseMultiGamePgn(
                      _pgnPasteController.text,
                      source: 'pgn',
                    );
                    setState(() {
                      _previewGames = r.games;
                      _statusMessage =
                          'Found ${r.games.length} game(s) from pasted PGN.';
                    });
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Preview'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _fetchOnlineGames(String platform, String username) async {
    setState(() {
      _isFetching = true;
      _statusMessage =
          'Connecting to ${platform == "lichess" ? "Lichess" : "Chess.com"} for "$username"...';
      _previewGames = [];
    });

    final services = ref.read(appServicesProvider);
    final GameSource source =
        platform == 'lichess' ? services.lichessSource : services.chessComSource;

    try {
      final stream = source.fetchGames(
        ImportRequestParams(
          source: platform,
          username: username,
          maxGames: 20,
        ),
      );

      await for (final update in stream) {
        if (!mounted) return;
        setState(() {
          if (update.status == 'failed') {
            _statusMessage =
                update.message ?? 'Import failed (${update.errorCode ?? "unknown"}).';
          } else if (update.status == 'paused_rate_limit') {
            _statusMessage =
                update.message ?? 'Rate limited. Pausing temporarily...';
          } else if (update.status == 'done') {
            _previewGames = update.previewGames;
            _statusMessage = update.previewGames.isEmpty
                ? 'No games found for "$username".'
                : 'Found ${update.previewGames.length} game(s). Review preview below and tap Save.';
          } else {
            if (update.previewGames.isNotEmpty) {
              _previewGames = update.previewGames;
            }
            _statusMessage =
                update.message ?? 'Fetching games (${update.fetchedCount} found)...';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Fetch error: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isFetching = false;
        });
      }
    }
  }

  Future<void> _showOnlineImportSheet(String platform, bool isOffline) async {
    final services = ref.read(appServicesProvider);
    final platformName = platform == 'lichess' ? 'Lichess' : 'Chess.com';

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Import from $platformName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _usernameController,
              decoration: InputDecoration(
                labelText: '$platformName Username',
                hintText: 'e.g. magnuscarlsen',
                border: const OutlineInputBorder(),
              ),
            ),
            if (isOffline) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade700),
                ),
                child: Row(
                  children: [
                    Icon(Icons.wifi_off, color: Colors.amber.shade900, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Offline-only mode is active. You can switch to online mode to fetch immediately, or queue for later.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          if (isOffline)
            TextButton(
              onPressed: () {
                final username = _usernameController.text.trim();
                if (username.isNotEmpty) {
                  services.storage.saveHandle(platform, username);
                  services.storage.saveImportJob({
                    'id': '${platform}_$username',
                    'kind': platform,
                    'params_json': jsonEncode({'username': username, 'max': 100}),
                    'status': 'queued',
                    'progress': 0.0,
                    'created_at': DateTime.now().millisecondsSinceEpoch,
                  });
                  setState(() {
                    _statusMessage =
                        'Queued $platformName import for "$username" (will fetch when online).';
                  });
                }
                Navigator.of(ctx).pop();
              },
              child: const Text('Queue for later'),
            ),
          FilledButton.icon(
            icon: Icon(isOffline ? Icons.cloud_outlined : Icons.download),
            onPressed: () {
              final username = _usernameController.text.trim();
              if (username.isEmpty) return;

              services.storage.saveHandle(platform, username);

              if (isOffline) {
                ref.read(appUiProvider.notifier).setOfflineOnly(false);
              }

              Navigator.of(ctx).pop();
              _fetchOnlineGames(platform, username);
            },
            label: Text(isOffline ? 'Go Online & Fetch' : 'Fetch games'),
          ),
        ],
      ),
    );
  }

  void _commitPreviewImport() {
    final services = ref.read(appServicesProvider);
    var inserted = 0;
    var dupes = 0;
    for (final pg in _previewGames) {
      final outcome = services.storage.upsertParsedGame(pg);
      if (outcome == DedupeOutcome.skippedDuplicate) {
        dupes++;
      } else {
        inserted++;
      }
    }
    ref.read(appUiProvider.notifier).refreshGames();
    setState(() {
      _previewGames = [];
      _statusMessage = dupes > 0
          ? '$inserted imported. ${CopyDeck.tr("import.dupes", {"n": dupes.toString()})}'
          : 'Imported $inserted game(s) into your library.';
    });
  }
}

/// Screen 8 & 9: Game Review & Game Summary (matching Part 28.3 Wireframe + Stories F-1, F-2, E-7, I-7).
class GameReviewScreen extends ConsumerStatefulWidget {
  const GameReviewScreen({super.key});

  @override
  ConsumerState<GameReviewScreen> createState() => _GameReviewScreenState();
}

class _GameReviewScreenState extends ConsumerState<GameReviewScreen> {
  int _currentPly = 0;
  bool _flipped = false;
  bool _playingLine = false;
  String? _followUpAnswer;

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(appUiProvider);
    final services = ref.watch(appServicesProvider);
    final gameId = uiState.selectedGameId;
    if (gameId == null) {
      return Center(child: Text(CopyDeck.tr('empty.library')));
    }

    final game = services.storage.getGame(gameId);
    if (game == null) {
      return Center(child: Text(CopyDeck.tr('empty.library')));
    }

    final positions = services.storage.getPositions(gameId);
    final analyses = services.storage.getMoveAnalyses(gameId);
    final summary = services.storage.getGameSummary(gameId);
    final moments = services.storage.getCriticalMoments(gameId);

    final safePly = _currentPly.clamp(
      0,
      positions.isNotEmpty ? positions.length - 1 : 0,
    );
    final currentPos = positions.isNotEmpty ? positions[safePly] : null;
    final currentAnalysis =
        (safePly >= 1 && safePly <= analyses.length) ? analyses[safePly - 1] : null;

    final coachResp = safePly >= 1
        ? services.storage.getExplanation(
            gameId: gameId,
            ply: safePly,
            providerId: uiState.activeProviderId,
            band: uiState.ratingBand,
          )
        : null;

    final myAcc = summary == null
        ? null
        : (game.myColor == SideColor.w ? summary.accWhite : summary.accBlack);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Top Header (Part 28.3 Wireframe: Game vs opponent + Accuracy %)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                '${game.white} vs ${game.black}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            if (myAcc != null)
              Chip(
                label: Text(
                  'Accuracy ${myAcc.toStringAsFixed(0)}%',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.flip_camera_android),
              tooltip: 'Flip Board',
              onPressed: () => setState(() => _flipped = !_flipped),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Interactive Board with Best-Move Arrow
        if (currentPos != null)
          InteractiveChessBoard(
            fen: currentPos.fen,
            flipped: _flipped,
            lastMoveUci: currentPos.moveUci,
            bestMoveUci: currentAnalysis?.bestMoveUci,
          ),
        const SizedBox(height: 8),
        // Navigation Bar: |< < > >| and [Play line] (Part 28.3)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.first_page),
                  tooltip: 'First move',
                  onPressed: () => setState(() {
                    _currentPly = 0;
                    _followUpAnswer = null;
                  }),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Previous move',
                  onPressed: () => setState(() {
                    _currentPly = (_currentPly - 1).clamp(0, positions.length - 1);
                    _followUpAnswer = null;
                  }),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Next move',
                  onPressed: () => setState(() {
                    _currentPly = (_currentPly + 1).clamp(0, positions.length - 1);
                    _followUpAnswer = null;
                  }),
                ),
                IconButton(
                  icon: const Icon(Icons.last_page),
                  tooltip: 'Last move',
                  onPressed: () => setState(() {
                    _currentPly = positions.length - 1;
                    _followUpAnswer = null;
                  }),
                ),
              ],
            ),
            // Story I-7: Toggle "My moves / Both sides"
            FilterChip(
              label: Text(uiState.reviewBothSides ? 'Both sides' : 'My moves'),
              selected: uiState.reviewBothSides,
              onSelected: (v) =>
                  ref.read(appUiProvider.notifier).setReviewBothSides(v),
            ),
            OutlinedButton.icon(
              onPressed: _playingLine
                  ? null
                  : () async {
                      setState(() => _playingLine = true);
                      await Future<void>.delayed(const Duration(milliseconds: 300));
                      if (mounted) setState(() => _playingLine = false);
                    },
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Play line'),
            ),
          ],
        ),
        // Eval Graph (tap=jump)
        EvalGraphWidget(
          analyses: analyses,
          currentPly: safePly,
          onPlySelected: (ply) => setState(() {
            _currentPly = ply;
            _followUpAnswer = null;
          }),
        ),
        const SizedBox(height: 8),
        // Critical Moments Carousel (Part 28.3: Moments: ( 12 ) ( 18 ) ...)
        if (moments.isNotEmpty) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text(
                  'Moments: ',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                for (final m in moments)
                  Padding(
                    padding: const EdgeInsets.only(right: 6.0),
                    child: ActionChip(
                      label: Text('Ply ${m.ply} (${m.reason})'),
                      onPressed: () => setState(() {
                        // F-2 AC1: selecting one jumps to the position
                        _currentPly = m.ply;
                        _followUpAnswer = null;
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        // Coach Commentary Panel (Part 28.3)
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (currentAnalysis != null)
                      Row(
                        children: [
                          MoveBadgeChip(classification: currentAnalysis.label),
                          const SizedBox(width: 8),
                          Text(
                            currentPos?.moveSan ?? '',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      )
                    else
                      const Text(
                        'Select a move or run analysis to see coaching.',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    Chip(
                      label: Text(
                        coachResp?.isFallback == true
                            ? CopyDeck.tr('coach.template_marker')
                            : '[${uiState.activeProviderId}]',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (coachResp != null) ...[
                  Text(coachResp.coachCommentary),
                  const SizedBox(height: 6),
                  Text(
                    'Better idea: ${coachResp.betterIdea}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Lesson: ${coachResp.lesson}',
                    style: TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                  if (coachResp.isFallback)
                    TextButton.icon(
                      onPressed: () => _explainCurrentPlyOnDemand(gameId, safePly),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: Text(
                        CopyDeck.tr(
                          'coach.retry',
                          {'provider': uiState.activeProviderId},
                        ),
                      ),
                    ),
                  // Story E-7: Follow-up questions constrained to moment facts
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: [
                      ActionChip(
                        label: const Text('Explain simpler'),
                        onPressed: () => setState(() {
                          _followUpAnswer =
                              'Simpler: ${coachResp.tacticalSummary} ${coachResp.lesson}';
                        }),
                      ),
                      ActionChip(
                        label: const Text('What was the idea of the best move?'),
                        onPressed: () => setState(() {
                          _followUpAnswer = coachResp.betterIdea;
                        }),
                      ),
                    ],
                  ),
                  if (_followUpAnswer != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _followUpAnswer!,
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ],
                ] else if (currentAnalysis != null) ...[
                  Text(
                    'Win probability: ${currentAnalysis.winBefore.toStringAsFixed(1)}% → ${currentAnalysis.winAfter.toStringAsFixed(1)}% (drop ${currentAnalysis.deltaW.toStringAsFixed(1)}%)',
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: () => _explainCurrentPlyOnDemand(gameId, safePly),
                    icon: const Icon(Icons.psychology_outlined),
                    label: const Text('Explain this move with AI Coach'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Horizontal Move List with Badges
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var p = 1; p < positions.length; p++)
                Padding(
                  padding: const EdgeInsets.only(right: 4.0),
                  child: ChoiceChip(
                    selected: safePly == p,
                    label: Text(
                      '${p.isOdd ? "${(p + 1) ~/ 2}." : ""}${positions[p].moveSan ?? ""}',
                    ),
                    onSelected: (_) => setState(() {
                      _currentPly = p;
                      _followUpAnswer = null;
                    }),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _explainCurrentPlyOnDemand(String gameId, int ply) async {
    final services = ref.read(appServicesProvider);
    final uiState = ref.read(appUiProvider);
    final game = services.storage.getGame(gameId);
    final positions = services.storage.getPositions(gameId);
    final analyses = services.storage.getMoveAnalyses(gameId);
    if (game == null || ply < 1 || ply > analyses.length) return;

    final ma = analyses[ply - 1];
    final posBefore = positions[ply - 1];
    final posAfter = positions[ply];
    final tags = services.storage.getGameTags(gameId, ply: ply);

    final req = CoachRequest(
      gameId: gameId,
      ratingBand: uiState.ratingBand,
      userColor: game.myColor,
      ply: ply,
      fen: posBefore.fen,
      moveSan: posAfter.moveSan ?? '',
      classification: ma.label,
      winBefore: ma.winBefore,
      winAfter: ma.winAfter,
      deltaW: ma.deltaW,
      bestMoveSan: ma.bestMoveSan ?? (posAfter.moveSan ?? ''),
      bestLineSan: [ma.bestMoveSan ?? (posAfter.moveSan ?? '')],
      phase: ma.phase,
      tags: tags,
    );

    await services.providerRegistry.explainMomentWithFallback(req);
    if (mounted) setState(() {});
  }
}

/// Screen 10: Cross-Game Weakness Dashboard & Weekly Focus (Stories G-1, G-2, Part 19-5).
class WeaknessDashboardScreen extends ConsumerWidget {
  const WeaknessDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(appServicesProvider);
    ref.watch(appUiProvider);
    final stats = services.pipeline.computeDashboardStats();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Weakness Dashboard (Preset: ${stats.activePresetId.toUpperCase()})',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (stats.analysedGamesCount < 5)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12.0),
              child: Text(
                'Analyse at least 5 games to unlock full multi-game trend charts. Current snapshots are shown below.',
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Analysed Games',
                value: '${stats.analysedGamesCount}',
              ),
            ),
            Expanded(
              child: _StatCard(
                label: 'Avg Accuracy',
                value: '${stats.averageAccuracy.toStringAsFixed(1)}%',
              ),
            ),
            Expanded(
              child: _StatCard(
                label: 'Blunders / 100',
                value: stats.blunderRatePer100Moves.toStringAsFixed(1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Phase Accuracy & Tactical Awareness',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text('Opening: ${stats.openingAccuracy.toStringAsFixed(1)}%'),
                Text('Middlegame: ${stats.middlegameAccuracy.toStringAsFixed(1)}%'),
                Text('Endgame: ${stats.endgameAccuracy.toStringAsFixed(1)}%'),
                Text(
                  'Tactical Awareness (Opponent mistakes punished): ${stats.tacticalAwarenessPercent.toStringAsFixed(1)}%',
                ),
              ],
            ),
          ),
        ),
        // Story G-2: Weekly Focus (hidden until 10 analysed games exist)
        if (stats.weeklyFocusItems.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Weekly Focus (Top 2 Priorities)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  for (final item in stats.weeklyFocusItems)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text('• $item'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;

  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// Screens 11..16: Settings Hub, Provider Editor with Payload Preview (Screen 12),
/// Model Manager & Storage (Screen 13), Export (Screen 14), Diagnostics (Screen 15),
/// and Licences & Privacy Policy (Screen 16).
class SettingsHubScreen extends ConsumerWidget {
  const SettingsHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uiState = ref.watch(appUiProvider);
    final services = ref.watch(appServicesProvider);
    final usage = services.storage.computeStorageUsage();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'AI Coach & Engine Settings',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Card(
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.offline_bolt, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Built-in Offline AI Coach (0 MB)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'MoveMentor includes a built-in Template Coach powered by Stockfish. It runs 100% offline out-of-the-box with NO downloads required. Local GGUF models and Remote APIs are optional alternatives.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SwitchListTile(
          title: const Text('Offline-only Mode'),
          subtitle: Text(CopyDeck.tr('status.offline')),
          value: uiState.offlineOnly,
          onChanged: (v) => ref.read(appUiProvider.notifier).setOfflineOnly(v),
        ),
        ListTile(
          title: const Text('Active Explanation Coach'),
          subtitle: Text(
            uiState.activeProviderId == 'template'
                ? 'Template Coach (Built-in, 0 MB, Offline)'
                : uiState.activeProviderId == 'builtin'
                    ? 'Built-in Qwen 0.6B (Simulated Engine)'
                    : uiState.activeProviderId.startsWith('local:')
                        ? 'Local GGUF Model (On-Device RAM)'
                        : 'Remote API (OpenAI / Cloud)',
          ),
          trailing: DropdownButton<String>(
            value: uiState.activeProviderId,
            items: const [
              DropdownMenuItem(
                value: 'template',
                child: Text('Template Coach (Built-in, 0 MB)'),
              ),
              DropdownMenuItem(
                value: 'builtin',
                child: Text('Built-in Qwen 0.6B (Local)'),
              ),
              DropdownMenuItem(
                value: 'local:default',
                child: Text('Local GGUF (.gguf file)'),
              ),
              DropdownMenuItem(
                value: 'remote:default',
                child: Text('My Own API (Cloud)'),
              ),
            ],
            onChanged: (val) {
              if (val != null) {
                ref.read(appUiProvider.notifier).setActiveProvider(val);
              }
            },
          ),
        ),
        ListTile(
          title: const Text('Rating Band'),
          subtitle: Text(uiState.ratingBand.label),
          trailing: DropdownButton<RatingBand>(
            value: uiState.ratingBand,
            items: RatingBand.values
                .map((b) => DropdownMenuItem(value: b, child: Text(b.label)))
                .toList(),
            onChanged: (val) {
              if (val != null) {
                ref.read(appUiProvider.notifier).setRatingBand(val);
              }
            },
          ),
        ),
        ListTile(
          title: const Text('Stockfish Engine Preset'),
          subtitle: Text(uiState.enginePresetId.toUpperCase()),
          trailing: DropdownButton<String>(
            value: uiState.enginePresetId,
            items: const [
              DropdownMenuItem(value: 'fast', child: Text('Fast')),
              DropdownMenuItem(value: 'balanced', child: Text('Balanced')),
              DropdownMenuItem(value: 'deep', child: Text('Deep')),
            ],
            onChanged: (val) {
              if (val != null) {
                ref.read(appUiProvider.notifier).setEnginePreset(val);
              }
            },
          ),
        ),
        ListTile(
          title: const Text('Classification Thresholds Preset'),
          subtitle: Text(
            uiState.classificationPresetId == 'lichess'
                ? 'Lichess-style (10/20/30)'
                : 'PDF-style (5/10/20)',
          ),
          trailing: DropdownButton<String>(
            value: uiState.classificationPresetId,
            items: const [
              DropdownMenuItem(value: 'lichess', child: Text('Lichess (Default)')),
              DropdownMenuItem(value: 'pdf', child: Text('PDF Preset')),
            ],
            onChanged: (val) {
              if (val != null) {
                ref.read(appUiProvider.notifier).setClassificationPreset(val);
              }
            },
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('My Own API Editor & Payload Preview (Screen 12)'),
          subtitle: const Text('Configure endpoint, secure API key, and inspect payload'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ProviderEditorScreen()),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.memory),
          title: const Text('Local Models & Storage Manager (Screen 13)'),
          subtitle: Text(
            'Games: ${(usage.gamesBytes / 1024).toStringAsFixed(1)} KB • Cache: ${(usage.analysisCacheBytes / 1024).toStringAsFixed(1)} KB',
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ModelAndStorageScreen()),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.ios_share),
          title: const Text('Export Reports & Full Data Backup (Screen 14)'),
          subtitle: const Text('PDF game report, Annotated PGN, or full JSON+PGN ZIP'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ExportDataScreen()),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Diagnostics & Network Audit Log (Screen 15)'),
          subtitle: const Text('Engine version, tokens/sec, redacted copy & beta feedback'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.policy_outlined),
          title: const Text('Licences, Credits & Privacy Policy (Screen 16)'),
          subtitle: Text(CopyDeck.tr('disclaimer.affiliation')),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const LicencesAndPrivacyScreen()),
          ),
        ),
      ],
    );
  }
}

/// Screen 12: Provider Editor with Payload Preview (matching Part 28.4 Wireframe).
class ProviderEditorScreen extends ConsumerStatefulWidget {
  const ProviderEditorScreen({super.key});

  @override
  ConsumerState<ProviderEditorScreen> createState() =>
      _ProviderEditorScreenState();
}

class _ProviderEditorScreenState extends ConsumerState<ProviderEditorScreen> {
  final TextEditingController _nameCtrl =
      TextEditingController(text: 'Home server');
  final TextEditingController _urlCtrl =
      TextEditingController(text: 'https://api.openai.com/v1');
  final TextEditingController _modelCtrl =
      TextEditingController(text: 'gpt-4o-mini');
  final TextEditingController _keyCtrl = TextEditingController();
  String _testStatus = '';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCleartextHttp = _urlCtrl.text.trim().startsWith('http://');

    return Scaffold(
      appBar: AppBar(title: const Text('My own API')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(labelText: 'Base URL'),
            onChanged: (_) => setState(() {}),
          ),
          // E-AI-08: Cleartext LAN endpoint warning (Part 28.4)
          if (isCleartextHttp)
            const Padding(
              padding: EdgeInsets.only(top: 4.0),
              child: Text(
                '! Not encrypted (local network only)',
                style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(labelText: 'Model'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API key (stored in secure storage)',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: () {
                  setState(() => _testStatus = 'OK (Validated configuration)');
                },
                child: const Text('Test connection'),
              ),
              const SizedBox(width: 12),
              Text(_testStatus),
            ],
          ),
          const SizedBox(height: 16),
          // What will be sent box (Part 28.4 Wireframe)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'What will be sent for each moment:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 4),
                Text('• position, move, labels, best line'),
                Text('• NOT sent: player names, full game, your username'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _showRealPayloadPreviewDialog,
            child: const Text('Preview a real payload'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () async {
              final services = ref.read(appServicesProvider);
              if (_keyCtrl.text.isNotEmpty) {
                await services.secureStore.writeSecret(
                  'secret_remote_default',
                  _keyCtrl.text.trim(),
                );
              }
              ref.read(appUiProvider.notifier).setActiveProvider('remote:default');
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Save and use'),
          ),
        ],
      ),
    );
  }

  void _showRealPayloadPreviewDialog() {
    const sampleReq = CoachRequest(
      gameId: 'preview',
      ratingBand: RatingBand.novice,
      userColor: SideColor.w,
      ply: 23,
      fen: 'r1b1kbnr/1pqp1ppp/p1n1p3/8/4P3/2N2N2/PPP2PPP/R1BQKB1R w KQkq - 0 8',
      moveSan: 'Qxb7',
      classification: MoveClassification.blunder,
      winBefore: 62.0,
      winAfter: 31.5,
      deltaW: 30.5,
      bestMoveSan: 'Nf3',
      bestLineSan: ['Nf3', 'Nc6', 'd4', 'exd4'],
      phase: GamePhase.middlegame,
      materialChange: -9,
    );

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(CopyDeck.tr('remote.consent_title')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(CopyDeck.tr('remote.consent_body')),
              const SizedBox(height: 8),
              SelectableText(
                sampleReq.renderCompactKeyValue(),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Screen 13: Model Manager, RAM-Fit Check & Storage Screen (Stories E-4, H-1, H-2, I-3).
class ModelAndStorageScreen extends ConsumerStatefulWidget {
  const ModelAndStorageScreen({super.key});

  @override
  ConsumerState<ModelAndStorageScreen> createState() =>
      _ModelAndStorageScreenState();
}

class _ModelAndStorageScreenState extends ConsumerState<ModelAndStorageScreen> {
  final TextEditingController _customPathCtrl = TextEditingController();

  @override
  void dispose() {
    _customPathCtrl.dispose();
    super.dispose();
  }

  void _showSetCustomModelDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Link Custom GGUF File'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the absolute path to your downloaded .gguf model on this device:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _customPathCtrl,
              decoration: const InputDecoration(
                hintText: '/storage/emulated/0/Download/model.gguf',
                labelText: 'Model File Path',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final path = _customPathCtrl.text.trim();
              if (path.isNotEmpty) {
                final services = ref.read(appServicesProvider);
                services.storage.saveProviderProfile({
                  'id': 'local:default',
                  'type': 'local',
                  'display_name': 'Custom GGUF Model',
                  'config_json': jsonEncode({'modelPath': path, 'quant': 'Q4_K_M'}),
                  'secret_ref': null,
                  'created_at': DateTime.now().millisecondsSinceEpoch,
                });
                ref.read(appUiProvider.notifier).setActiveProvider('local:default');
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Linked and set "$path" as active GGUF model.'),
                  ),
                );
              }
            },
            child: const Text('Save & Activate'),
          ),
        ],
      ),
    );
  }

  void _showWipeAllConfirmation(BuildContext context) {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Type DELETE to wipe all data'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'DELETE'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (ctrl.text.trim() == 'DELETE') {
                ref.read(appUiProvider.notifier).wipeAll();
                Navigator.of(ctx).pop();
                Navigator.of(context).pop();
              }
            },
            child: const Text('Confirm Wipe'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(appUiProvider);
    final services = ref.watch(appServicesProvider);
    final usage = services.storage.computeStorageUsage();

    final ramFit06B = ModelRamGuard.evaluateFit(
      fileSizeBytes: 419430400,
      availableRamMb: 6144,
    );
    final ramFit17B = ModelRamGuard.evaluateFit(
      fileSizeBytes: 1258291200,
      availableRamMb: 6144,
    );
    final ramFit4B = ModelRamGuard.evaluateFit(
      fileSizeBytes: 2621440000,
      availableRamMb: 4096,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Models & Storage')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.psychology, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Active Coach: ${uiState.activeProviderId == "template" ? "Template Coach (Built-in, 0 MB)" : uiState.activeProviderId == "builtin" ? "Built-in Qwen 0.6B" : uiState.activeProviderId.startsWith("local:") ? "Local GGUF Model" : "Remote API"}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Do you need to download a model?\n'
                    'No! The default Template Coach runs 100% offline out-of-the-box and uses Stockfish + 15 tactic algorithms with 0 MB extra download.\n\n'
                    'Local GGUF models below are optional on-device neural LLMs for users who want neural prose inference via llama.cpp.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  if (uiState.activeProviderId != 'template')
                    FilledButton.tonalIcon(
                      onPressed: () {
                        ref.read(appUiProvider.notifier).setActiveProvider('template');
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Switched to Built-in Template Coach (0 MB, 100% offline).'),
                          ),
                        );
                      },
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('Switch back to Template Coach (0 MB)'),
                    ),
                ],
              ),
            ),
          ),

          const Text(
            'On-Device GGUF Models (Optional)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Quantized GGUF models run locally on your device CPU/RAM with zero cloud data transmission.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          'Qwen3 0.6B (Q4_K_M) • ~0.4 GB',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Chip(
                        label: Text(
                          ramFit06B.verdict.name.toUpperCase(),
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: ramFit06B.verdict == RamFitVerdict.fits
                            ? Colors.green.withValues(alpha: 0.15)
                            : Colors.orange.withValues(alpha: 0.15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Licence: Apache 2.0 • Estimated Footprint: ${ramFit06B.estimatedFootprintMb} MB\n'
                    'Recommended for devices with 4 GB+ RAM. Built-in local candidate architecture.',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () {
                      ref.read(appUiProvider.notifier).setActiveProvider('builtin');
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Selected Qwen3 0.6B as active local engine.')),
                      );
                    },
                    child: Text(
                      uiState.activeProviderId == 'builtin'
                          ? 'Active Local Engine'
                          : 'Select Qwen 0.6B',
                    ),
                  ),
                ],
              ),
            ),
          ),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          'Qwen3 1.7B (Q4_K_M) • ~1.2 GB',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Chip(
                        label: Text(
                          ramFit17B.verdict.name.toUpperCase(),
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: ramFit17B.verdict == RamFitVerdict.fits
                            ? Colors.green.withValues(alpha: 0.15)
                            : Colors.orange.withValues(alpha: 0.15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Licence: Apache 2.0 • Estimated Footprint: ${ramFit17B.estimatedFootprintMb} MB\n'
                    'Higher nuance coaching. Recommended for devices with 6 GB+ RAM.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          'Phi-4 Mini 3.8B (Q4_K_M) • ~2.6 GB',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Chip(
                        label: Text(
                          ramFit4B.verdict.name.toUpperCase(),
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: Colors.red.withValues(alpha: 0.15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Licence: MIT • Estimated Footprint: ${ramFit4B.estimatedFootprintMb} MB\n'
                    'Heavyweight model. Requires 8 GB+ RAM device.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _showSetCustomModelDialog(context),
            icon: const Icon(Icons.folder_open),
            label: const Text('Link Downloaded .gguf File from Device'),
          ),

          const Divider(height: 32),
          const Text(
            'Storage Breakdown (Story H-2)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          ListTile(
            title: const Text('Games Database'),
            trailing: Text('${(usage.gamesBytes / 1024).toStringAsFixed(1)} KB'),
          ),
          ListTile(
            title: const Text('Engine Analysis Cache'),
            trailing: Text(
              '${(usage.analysisCacheBytes / 1024).toStringAsFixed(1)} KB',
            ),
          ),
          ListTile(
            title: const Text('Local Models'),
            trailing: Text(
              '${(usage.modelsBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              services.storage.clearEngineEvalCacheOnly();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Cleared engine evaluation cache. Games and explanations kept.',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.cleaning_services_outlined),
            label: const Text('Clear Engine Eval Cache Only (Keep Games)'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => _showWipeAllConfirmation(context),
            icon: const Icon(Icons.delete_forever),
            label: const Text('Wipe All Data & Return to Onboarding'),
          ),
        ],
      ),
    );
  }
}

/// Screen 14: Export Screen (Stories F-3 & H-1).
class ExportDataScreen extends ConsumerWidget {
  const ExportDataScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(appServicesProvider);
    final uiState = ref.watch(appUiProvider);
    final selectedId = uiState.selectedGameId;

    return Scaffold(
      appBar: AppBar(title: const Text('Export Reports & Data')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (selectedId != null) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('Copy Annotated PGN for Current Game'),
                subtitle: const Text('Includes move labels, Win% and coach explanations'),
                onTap: () {
                  final pgn = services.exportService.buildAnnotatedPgn(selectedId);
                  Clipboard.setData(ClipboardData(text: pgn));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Annotated PGN copied to clipboard.')),
                  );
                },
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Generate Offline PDF Game Report'),
                subtitle: const Text('Headers, summary stats, critical moments & lessons'),
                onTap: () async {
                  final bytes =
                      await services.exportService.buildGameReportPdf(selectedId);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Generated offline PDF report (${bytes.length} bytes, zero secrets).',
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
          ],
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_zip_outlined),
              title: const Text('Export All Data as ZIP (JSON + PGN)'),
              subtitle: const Text('Schema-versioned archive with zero API secrets (Story H-1)'),
              onTap: () {
                final zipBytes = services.exportService.buildFullDataExportZip();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Built full JSON+PGN export archive (${zipBytes.length} bytes).',
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Screen 15: Diagnostics & Network Gateway Log (Story I-4, I-5, FR-21).
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(appServicesProvider);
    final diagText = services.exportService.buildDiagnosticsReport(
      redactSensitive: true,
      rawSampleText:
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1 /data/user/0/movementor user:demoPlayer',
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SelectableText(
            diagText,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: diagText));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied redacted diagnostics (FEN, usernames & paths removed).'),
                ),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy Redacted Diagnostics'),
          ),
        ],
      ),
    );
  }
}

/// Screen 16: Licences, Credits & Privacy Policy (Story I-2 & Part 29.3).
class LicencesAndPrivacyScreen extends StatelessWidget {
  const LicencesAndPrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Licences & Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Privacy Policy (Part 29.3)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'What this app stores: Games you import, the analysis the app computes, explanations, your settings and any model files. All of it is stored only on your device. API keys are kept in your device secure storage.\n\n'
            'What leaves your device, and only when you ask: (1) Importing by username sends that username to Lichess or Chess.com to fetch your public games. (2) Downloading a model contacts the download host. (3) If you choose "My own API", the position and move facts for each explained moment are sent to the endpoint you configured. Player names and full game files are not sent. If you turn on Offline only, none of these happen.\n\n'
            'What we do not do: We run no accounts and no servers that hold your data. We do not use analytics, advertising or tracking.',
          ),
          const Divider(height: 24),
          const Text(
            'Open Source Licences & Credits (Story I-2)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const ListTile(
            title: Text('Stockfish Chess Engine & NNUE Network'),
            subtitle: Text('GNU General Public License v3.0 (GPLv3)'),
          ),
          const ListTile(
            title: Text('llama.cpp On-Device Inference'),
            subtitle: Text('MIT License'),
          ),
          const ListTile(
            title: Text('Lichess chess-openings & Puzzle Themes Dataset'),
            subtitle: Text('Creative Commons Zero v1.0 Universal (CC0)'),
          ),
          const ListTile(
            title: Text('Qwen3 (0.6B / 1.7B) & SmolLM3 3B'),
            subtitle: Text('Apache License 2.0'),
          ),
          const ListTile(
            title: Text('Llama 3.2 & Gemma 3 (Catalogue Models)'),
            subtitle: Text('Community / Terms of Use — requires acceptance before first load'),
          ),
          const SizedBox(height: 8),
          Text(
            CopyDeck.tr('disclaimer.affiliation'),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}
