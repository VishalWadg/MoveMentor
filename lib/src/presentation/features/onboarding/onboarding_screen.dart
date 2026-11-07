import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/app_state.dart';
import '../../../application/copy_deck.dart';
import '../../../domain/chess/chess_models.dart';

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
            runSpacing: 8,
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
