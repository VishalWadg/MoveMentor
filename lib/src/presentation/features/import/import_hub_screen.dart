import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../adapters/storage/sqlite_storage_adapter.dart';
import '../../../application/app_state.dart';
import '../../../application/copy_deck.dart';
import '../../../domain/chess/pgn_parser.dart';
import '../../../ports/ports.dart';

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
