import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/app_state.dart';

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
