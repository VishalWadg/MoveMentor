import 'dart:convert';
import 'dart:io';
import 'package:chess/chess.dart' as ch;

/// Regenerates the opening table from the Lichess chess-openings dataset (CC0)
/// by replaying moves and verifying that every FEN parses and round-trips.
Future<void> main() async {
  final cacheDir = Directory('tool/cache/lichess_openings');
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
  }

  final files = ['a.tsv', 'b.tsv', 'c.tsv', 'd.tsv', 'e.tsv'];
  final client = HttpClient();

  final openingsMap = <String, Map<String, dynamic>>{};
  var totalParsed = 0;
  var totalErrors = 0;

  for (final filename in files) {
    final cachedFile = File('${cacheDir.path}/$filename');
    String tsvContent;

    if (cachedFile.existsSync() && cachedFile.lengthSync() > 0) {
      stdout.writeln('Using cached $filename...');
      tsvContent = cachedFile.readAsStringSync();
    } else {
      stdout.writeln('Downloading $filename from lichess-org/chess-openings (CC0)...');
      final url = Uri.parse(
        'https://raw.githubusercontent.com/lichess-org/chess-openings/master/$filename',
      );
      final req = await client.getUrl(url);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        stderr.writeln('Failed to download $filename: status ${resp.statusCode}');
        exit(1);
      }
      tsvContent = await resp.transform(utf8.decoder).join();
      cachedFile.writeAsStringSync(tsvContent);
    }

    final lines = tsvContent.split('\n');
    var isHeader = true;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (isHeader) {
        isHeader = false;
        continue; // Skip header: eco \t name \t pgn
      }

      final parts = trimmed.split('\t');
      if (parts.length < 3) continue;

      final eco = parts[0].trim();
      final name = parts[1].trim();
      final pgn = parts[2].trim();

      try {
        final game = ch.Chess();
        // Parse moves from PGN
        // Format example: "1. e4 e5 2. Nf3 Nc6"
        final tokens = pgn.split(RegExp(r'\s+'));
        var ply = 0;

        for (final token in tokens) {
          if (token.isEmpty) continue;
          if (RegExp(r'^\d+\.+$').hasMatch(token)) continue; // Move number e.g. "1."
          if (token == '*' || token == '1-0' || token == '0-1' || token == '1/2-1/2') continue;

          // Strip move number prefix if glued e.g. "1.e4"
          final cleanSan = token.replaceAll(RegExp(r'^\d+\.+'), '');
          final move = game.move(cleanSan);
          if (move == false) {
            throw FormatException('Illegal move: $cleanSan in $pgn');
          }
          ply++;
        }

        final fullFen = game.fen;

        // Round-trip verification: parse back from FEN
        final roundTripGame = ch.Chess.fromFEN(fullFen);
        if (roundTripGame.fen != fullFen) {
          throw FormatException('Round-trip FEN mismatch: $fullFen != ${roundTripGame.fen}');
        }

        // Standard EPD: first 4 fields (piece placement, active color, castling, en passant)
        final fenParts = fullFen.split(' ');
        final epd = '${fenParts[0]} ${fenParts[1]} ${fenParts[2]} ${fenParts[3]}';

        totalParsed++;

        // Store by EPD (longer ply / more specific variation preferred)
        if (!openingsMap.containsKey(epd) || (openingsMap[epd]!['ply'] as int) < ply) {
          openingsMap[epd] = {
            'epd': epd,
            'fen': fullFen,
            'eco': eco,
            'name': name,
            'ply': ply,
            'pgn': pgn,
          };
        }
      } catch (e) {
        totalErrors++;
        stderr.writeln('Error processing [$eco] $name ($pgn): $e');
      }
    }
  }

  client.close();

  stdout.writeln('Parsed $totalParsed openings across A-E ($totalErrors errors).');
  stdout.writeln('Unique EPD positions: ${openingsMap.length}.');

  // Convert to sorted list by ECO and ply
  final list = openingsMap.values.toList()
    ..sort((a, b) {
      final ecoCmp = (a['eco'] as String).compareTo(b['eco'] as String);
      if (ecoCmp != 0) return ecoCmp;
      return (a['ply'] as int).compareTo(b['ply'] as int);
    });

  // Verify every single entry once more
  for (final item in list) {
    final fen = item['fen'] as String;
    final testGame = ch.Chess.fromFEN(fen);
    assert(testGame.fen == fen, 'FEN round-trip failed for $fen');
  }

  final outFile = File('assets/openings/eco_openings.json');
  const encoder = JsonEncoder.withIndent('  ');
  outFile.writeAsStringSync(encoder.convert(list));

  stdout.writeln('Successfully wrote ${list.length} verified openings to ${outFile.path}!');
}
