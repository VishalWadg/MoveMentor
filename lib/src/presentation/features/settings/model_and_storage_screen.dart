import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../adapters/providers/llama_and_remote_providers.dart';
import '../../../application/app_state.dart';

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
