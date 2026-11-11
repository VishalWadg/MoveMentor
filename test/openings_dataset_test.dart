import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess/chess.dart' as ch;

void main() {
  test('Lichess ECO openings dataset: every entry parses and round-trips correctly', () {
    final file = File('assets/openings/eco_openings.json');
    expect(file.existsSync(), isTrue, reason: 'assets/openings/eco_openings.json must exist');

    final jsonContent = file.readAsStringSync();
    final list = (jsonDecode(jsonContent) as List<dynamic>).cast<Map<String, dynamic>>();

    expect(list.length, greaterThanOrEqualTo(3000),
        reason: 'Should contain full Lichess opening dataset (~3,865 entries)');

    for (final entry in list) {
      final fen = entry['fen'] as String?;
      final epd = entry['epd'] as String;
      final eco = entry['eco'] as String;
      final name = entry['name'] as String;

      expect(eco, isNotEmpty);
      expect(name, isNotEmpty);
      expect(epd, isNotEmpty);

      // Verify EPD has exactly 4 fields
      final epdParts = epd.split(' ');
      expect(epdParts.length, equals(4),
          reason: 'EPD must have exactly 4 fields (placement, turn, castling, en-passant) for $name');

      // Verify FEN round-trips if full FEN is present
      if (fen != null) {
        final game = ch.Chess.fromFEN(fen);
        expect(game.fen, equals(fen),
            reason: 'FEN failed round-trip for [$eco] $name');
      }
    }
  });
}
