import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/app_state.dart';
import '../../../application/copy_deck.dart';
import '../../../domain/chess/chess_models.dart';
import 'diagnostics_screen.dart';
import 'export_data_screen.dart';
import 'licences_screen.dart';
import 'model_and_storage_screen.dart';
import 'provider_editor_screen.dart';

/// Screen 11: Settings Hub (navigation to Screens 12..16).
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
          contentPadding: EdgeInsets.zero,
          title: const Text('Offline-only Mode'),
          subtitle: Text(CopyDeck.tr('status.offline')),
          value: uiState.offlineOnly,
          onChanged: (v) => ref.read(appUiProvider.notifier).setOfflineOnly(v),
        ),
        _SettingsDropdownTile<String>(
          title: 'Active Explanation Coach',
          subtitle: uiState.activeProviderId == 'template'
              ? 'Template Coach (Built-in, 0 MB, Offline)'
              : uiState.activeProviderId == 'builtin'
                  ? 'Built-in Qwen 0.6B (Simulated Engine)'
                  : uiState.activeProviderId.startsWith('local:')
                      ? 'Local GGUF Model (On-Device RAM)'
                      : 'Remote API (OpenAI / Cloud)',
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
        _SettingsDropdownTile<RatingBand>(
          title: 'Rating Band',
          subtitle: uiState.ratingBand.label,
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
        _SettingsDropdownTile<String>(
          title: 'Stockfish Engine Preset',
          subtitle: uiState.enginePresetId.toUpperCase(),
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
        _SettingsDropdownTile<String>(
          title: 'Classification Thresholds Preset',
          subtitle: uiState.classificationPresetId == 'lichess'
              ? 'Lichess-style (10/20/30)'
              : 'PDF-style (5/10/20)',
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
        SwitchListTile(
          key: const Key('use_new_classifier_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Use New Classifier (v2)'),
          subtitle: Text(
            uiState.useNewClassifier
                ? 'Active: chess_review_core (PV sacrifices & composite accuracy).'
                : 'Legacy fallback active. Enable for recommended review accuracy.',
          ),
          value: uiState.useNewClassifier,
          onChanged: (v) =>
              ref.read(appUiProvider.notifier).setUseNewClassifier(v),
        ),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('My Own API Editor & Payload Preview (Screen 12)'),
          subtitle: const Text('Configure endpoint, secure API key, and inspect payload'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ProviderEditorScreen()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.memory),
          title: const Text('Local Models & Storage Manager (Screen 13)'),
          subtitle: Text(
            'Games: ${(usage.gamesBytes / 1024).toStringAsFixed(1)} KB • Cache: ${(usage.analysisCacheBytes / 1024).toStringAsFixed(1)} KB',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ModelAndStorageScreen()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.ios_share),
          title: const Text('Export Reports & Full Data Backup (Screen 14)'),
          subtitle: const Text('PDF game report, Annotated PGN, or full JSON+PGN ZIP'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ExportDataScreen()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Diagnostics & Network Audit Log (Screen 15)'),
          subtitle: const Text('Engine version, tokens/sec, redacted copy & beta feedback'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.policy_outlined),
          title: const Text('Licences, Credits & Privacy Policy (Screen 16)'),
          subtitle: Text(CopyDeck.tr('disclaimer.affiliation')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const LicencesAndPrivacyScreen()),
          ),
        ),
      ],
    );
  }
}

class _SettingsDropdownTile<T> extends StatelessWidget {
  final String title;
  final String? subtitle;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _SettingsDropdownTile({
    required this.title,
    this.subtitle,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          InputDecorator(
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                isDense: true,
                items: items,
                selectedItemBuilder: (context) {
                  return items.map((item) {
                    final child = item.child;
                    if (child is Text) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          child.data ?? '',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      );
                    }
                    return child;
                  }).toList();
                },
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

