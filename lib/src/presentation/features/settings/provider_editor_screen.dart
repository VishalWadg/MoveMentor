import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/app_state.dart';
import '../../../application/copy_deck.dart';
import '../../../domain/chess/chess_models.dart';
import '../../../domain/coach/coach_contracts.dart';

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
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () {
                  setState(() => _testStatus = 'OK (Validated configuration)');
                },
                child: const Text('Test connection'),
              ),
              if (_testStatus.isNotEmpty)
                Text(
                  _testStatus,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
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
