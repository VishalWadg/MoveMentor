import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/analysis_pipeline_service.dart';
import '../../../application/app_state.dart';
import '../../../application/copy_deck.dart';
import '../../../domain/chess/chess_models.dart';
import '../../../domain/coach/coach_contracts.dart';
import '../import/import_hub_screen.dart';

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
