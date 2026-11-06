import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/app_state.dart';

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
