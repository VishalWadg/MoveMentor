import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/app_state.dart';

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
