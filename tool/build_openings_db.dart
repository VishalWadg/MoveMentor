import 'dart:convert';
import 'dart:io';

/// Part 27.1: CI build/verification script for the Lichess CC0 chess-openings dataset.
/// Converts or verifies the pinned opening book entries (epd, eco, name, ply).
void main(List<String> args) {
  final file = File('assets/openings/eco_openings.json');
  if (!file.existsSync()) {
    stderr.writeln('Error: assets/openings/eco_openings.json not found.');
    exit(1);
  }
  final raw = file.readAsStringSync();
  final decoded = jsonDecode(raw) as List<dynamic>;
  if (decoded.isEmpty) {
    stderr.writeln('Error: opening book is empty.');
    exit(1);
  }
  for (final item in decoded) {
    final map = item as Map<String, dynamic>;
    if (!map.containsKey('epd') ||
        !map.containsKey('eco') ||
        !map.containsKey('name') ||
        !map.containsKey('ply')) {
      stderr.writeln('Invalid opening entry: $map');
      exit(1);
    }
  }
  stdout.writeln(
    'Verified ${decoded.length} CC0 ECO opening entries in assets/openings/eco_openings.json.',
  );
}
