import 'dart:convert';
import 'package:chess/chess.dart' as ch;
import 'package:uuid/uuid.dart';
import 'chess_models.dart';
import 'fen_normalizer.dart';

class ParsedPgnGame {
  final GameEntity game;
  final List<PositionEntity> positions;
  final Map<int, int> clocksMs;
  final Map<int, double> serverEvals;
  final String? errorCode;
  final String? warningMessage;

  const ParsedPgnGame({
    required this.game,
    required this.positions,
    this.clocksMs = const {},
    this.serverEvals = const {},
    this.errorCode,
    this.warningMessage,
  });
}

class PgnImportReport {
  final List<ParsedPgnGame> games;
  final int totalFound;
  final int partiallyValidCount;
  final int nonAnalysableCount;
  final String? topLevelErrorCode;

  const PgnImportReport({
    required this.games,
    required this.totalFound,
    required this.partiallyValidCount,
    required this.nonAnalysableCount,
    this.topLevelErrorCode,
  });
}

/// Part 10.3 & 26.5: Tolerant PGN parser supporting UTF-8/BOM/Latin-1, missing tag pairs,
/// nested variations, comments with %clk/%eval,NAGs, [SetUp "1"]+[FEN], Chess960 detection,
/// and partial-validity recovery on illegal moves (E-IMP-06).
class PgnParser {
  static const int maxFileBytes = 50 * 1024 * 1024; // 50 MB (E-IMP-07)
  static const int maxGamesPerImport = 5000; // 5,000 games (E-IMP-07)
  static const _uuid = Uuid();

  /// Decodes raw bytes with UTF-8 BOM stripping and Latin-1 fallback (Part 10.3).
  static String decodeBytes(List<int> bytes) {
    var slice = bytes;
    if (slice.length >= 3 &&
        slice[0] == 0xEF &&
        slice[1] == 0xBB &&
        slice[2] == 0xBF) {
      slice = slice.sublist(3);
    }
    try {
      return utf8.decode(slice);
    } catch (_) {
      return latin1.decode(slice);
    }
  }

  static PgnImportReport parseMultiGamePgn(
    String rawText, {
    String source = 'pgn',
    List<String> savedUsernames = const [],
    String engineVersion = 'Stockfish-16.1',
    String settingsHash = 'default',
  }) {
    // Strip UTF-8 BOM character if present in string
    final cleaned = rawText
        .replaceFirst(RegExp(r'^\uFEFF'), '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();

    if (cleaned.isEmpty) {
      return const PgnImportReport(
        games: [],
        totalFound: 0,
        partiallyValidCount: 0,
        nonAnalysableCount: 0,
        topLevelErrorCode: 'E-IMP-05',
      );
    }

    final chunks = _splitIntoGames(cleaned);
    final topError = chunks.length > maxGamesPerImport ? 'E-IMP-07' : null;
    final limitedChunks = chunks.take(maxGamesPerImport).toList();

    final parsedGames = <ParsedPgnGame>[];
    var partialCount = 0;
    var nonAnalysableCount = 0;

    for (final chunk in limitedChunks) {
      final parsed = _parseSingleGame(
        chunk,
        source: source,
        savedUsernames: savedUsernames,
        engineVersion: engineVersion,
        settingsHash: settingsHash,
      );
      if (parsed != null) {
        parsedGames.add(parsed);
        if (parsed.game.status == 'partially_valid') partialCount++;
        if (parsed.game.status == 'not_analysable') nonAnalysableCount++;
      }
    }

    if (parsedGames.isEmpty) {
      return const PgnImportReport(
        games: [],
        totalFound: 0,
        partiallyValidCount: 0,
        nonAnalysableCount: 0,
        topLevelErrorCode: 'E-IMP-05',
      );
    }

    return PgnImportReport(
      games: parsedGames,
      totalFound: chunks.length,
      partiallyValidCount: partialCount,
      nonAnalysableCount: nonAnalysableCount,
      topLevelErrorCode: topError,
    );
  }

  static List<String> _splitIntoGames(String text) {
    final lines = text.split('\n');
    final games = <String>[];
    final current = StringBuffer();
    var inMovetext = false;

    for (final line in lines) {
      final trimmed = line.trim();
      final isTag = trimmed.startsWith('[') && trimmed.endsWith(']');
      if (isTag && inMovetext) {
        final built = current.toString().trim();
        if (built.isNotEmpty) games.add(built);
        current.clear();
        inMovetext = false;
      } else if (!isTag && trimmed.isNotEmpty) {
        inMovetext = true;
      }
      current.writeln(line);
    }
    final last = current.toString().trim();
    if (last.isNotEmpty) games.add(last);
    return games;
  }

  static ParsedPgnGame? _parseSingleGame(
    String pgnChunk, {
    required String source,
    required List<String> savedUsernames,
    required String engineVersion,
    required String settingsHash,
  }) {
    final headers = <String, String>{};
    final movetextLines = <String>[];
    final tagRegex = RegExp(r'^\[\s*([A-Za-z0-9_]+)\s+"((?:\\"|[^"])*)"\s*\]$');

    for (final line in pgnChunk.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final match = tagRegex.firstMatch(trimmed);
      if (match != null) {
        final key = match.group(1)!;
        final val = match.group(2)!.replaceAll(r'\"', '"');
        // First tag pair wins or overwrites cleanly (duplicate tag pair tolerance)
        headers.putIfAbsent(key, () => val);
      } else if (!trimmed.startsWith('%')) {
        // Strip inline ';' comments
        final semiIdx = line.indexOf(';');
        final content = semiIdx >= 0 ? line.substring(0, semiIdx) : line;
        movetextLines.add(content);
      }
    }

    final rawMovesText = movetextLines.join(' ').trim();
    if (rawMovesText.isEmpty && headers.isEmpty) return null;

    final variant = (headers['Variant'] ?? headers['Rules'] ?? 'standard').trim();
    final isChess960 = variant.toLowerCase().contains('960') ||
        variant.toLowerCase().contains('fischer') ||
        (variant.toLowerCase() != 'standard' && variant.toLowerCase() != 'chess');

    final startFen = (headers['SetUp'] == '1' && headers['FEN'] != null)
        ? headers['FEN']!.trim()
        : FenNormalizer.startFen;

    final clocksMs = <int, int>{};
    final serverEvals = <int, double>{};

    // Extract comments (%clk and %eval) before stripping braces
    final tokensWithComments = _tokeniseMovetext(
      rawMovesText,
      clocksMs: clocksMs,
      serverEvals: serverEvals,
    );

    final gameId = _uuid.v4();
    final chess = ch.Chess();
    var validSetup = true;
    if (startFen != FenNormalizer.startFen) {
      validSetup = chess.load(startFen);
    }

    final positions = <PositionEntity>[
      PositionEntity(
        gameId: gameId,
        ply: 0,
        fen: chess.fen,
        positionKey: FenNormalizer.computePositionKey(
          fen: chess.fen,
          engineVersion: engineVersion,
          settingsHash: settingsHash,
        ),
      ),
    ];

    final legalMovesSan = <String>[];
    String? errorCode;
    String? warningMsg;
    var status = isChess960 ? 'not_analysable' : 'imported';
    if (isChess960) {
      errorCode = 'E-IMP-08';
      warningMsg = 'Non-standard variant ($variant) is stored but not analysable in MVP.';
    } else if (!validSetup) {
      status = 'partially_valid';
      errorCode = 'E-IMP-06';
      warningMsg = 'Invalid start FEN in PGN.';
    } else {
      var ply = 0;
      for (final rawToken in tokensWithComments) {
        final normToken = _normaliseSanToken(rawToken);
        if (normToken.isEmpty) continue;
        // Null move handling (-- or Z0)
        if (normToken == '--' || normToken == 'Z0') {
          status = 'partially_valid';
          errorCode = 'E-IMP-06';
          warningMsg = 'Null move at ply ${ply + 1}; kept valid prefix.';
          break;
        }
        final moveObj = _findLegalMove(chess, normToken);
        if (moveObj == null) {
          status = 'partially_valid';
          errorCode = 'E-IMP-06';
          warningMsg = 'Illegal move "$rawToken" at ply ${ply + 1}; kept valid prefix.';
          break;
        }
        final canonicalSan = chess.move_to_san(moveObj);
        final uci =
            '${moveObj.fromAlgebraic}${moveObj.toAlgebraic}${moveObj.promotion?.name ?? ''}';
        chess.move(moveObj);
        ply++;
        legalMovesSan.add(canonicalSan);
        positions.add(
          PositionEntity(
            gameId: gameId,
            ply: ply,
            fen: chess.fen,
            positionKey: FenNormalizer.computePositionKey(
              fen: chess.fen,
              engineVersion: engineVersion,
              settingsHash: settingsHash,
            ),
            moveSan: canonicalSan,
            moveUci: uci,
            clockMs: clocksMs[ply],
          ),
        );
      }
    }

    if (legalMovesSan.isEmpty && !isChess960 && headers.isEmpty) {
      return null;
    }

    final white = headers['White'] ?? 'White';
    final black = headers['Black'] ?? 'Black';
    final result = headers['Result'] ?? '*';
    final dateStr = headers['UTCDate'] ?? headers['Date'] ?? '2026.01.01';
    final myColor = _detectMyColor(white, black, savedUsernames);
    final sourceGameId = _extractSourceGameId(headers, source);

    final gameEntity = GameEntity(
      id: gameId,
      fingerprint: FenNormalizer.computeFingerprint(
        white: white,
        black: black,
        date: dateStr,
        result: result,
        round: headers['Round'] ?? '',
        event: headers['Event'] ?? '',
        site: headers['Site'] ?? '',
        movesSan: legalMovesSan,
      ),
      movesHash: FenNormalizer.computeMovesHash(legalMovesSan),
      source: source,
      sourceGameId: sourceGameId,
      url: headers['Site']?.startsWith('http') == true
          ? headers['Site']
          : headers['Link'],
      white: white,
      black: black,
      whiteRating: int.tryParse(headers['WhiteElo'] ?? ''),
      blackRating: int.tryParse(headers['BlackElo'] ?? ''),
      result: result,
      termination: headers['Termination'],
      event: headers['Event'],
      site: headers['Site'],
      playedAt: _parseDateToEpochMs(dateStr, headers['UTCTime']),
      timeControl: headers['TimeControl'],
      timeClass: _inferTimeClass(headers['TimeControl'], headers['Event']),
      variant: isChess960 ? variant : 'standard',
      eco: headers['ECO'],
      openingName: headers['Opening'],
      startFen: startFen == FenNormalizer.startFen ? null : startFen,
      pgnRaw: pgnChunk,
      movesSan: legalMovesSan,
      myColor: myColor,
      status: status,
      importedAt: DateTime.now().millisecondsSinceEpoch,
    );

    return ParsedPgnGame(
      game: gameEntity,
      positions: positions,
      clocksMs: clocksMs,
      serverEvals: serverEvals,
      errorCode: errorCode,
      warningMessage: warningMsg,
    );
  }

  /// Strips nested variations `(...)`, extracts `%clk` and `%eval` from `{...}`, and returns move tokens.
  static List<String> _tokeniseMovetext(
    String text, {
    required Map<int, int> clocksMs,
    required Map<int, double> serverEvals,
  }) {
    final buf = StringBuffer();
    var variationDepth = 0;
    var inComment = false;
    final commentBuf = StringBuffer();
    var approxPly = 0;
    final tokens = <String>[];

    void flushWord() {
      final word = buf.toString().trim();
      buf.clear();
      if (word.isEmpty) return;
      // Ignore move numbers like 1. or 12... and results
      final stripped = word.replaceFirst(RegExp(r'^\d+\.+'), '').trim();
      if (stripped.isEmpty) return;
      if (stripped == '1-0' ||
          stripped == '0-1' ||
          stripped == '1/2-1/2' ||
          stripped == '*') {
        return;
      }
      if (stripped.startsWith(r'$')) return; // NAG
      tokens.add(stripped);
      approxPly++;
    }

    for (var i = 0; i < text.length; i++) {
      final chChar = text[i];
      if (inComment) {
        if (chChar == '}') {
          inComment = false;
          final comment = commentBuf.toString();
          commentBuf.clear();
          _parseCommentAnnotations(comment, approxPly, clocksMs, serverEvals);
        } else {
          commentBuf.write(chChar);
        }
        continue;
      }
      if (chChar == '{') {
        flushWord();
        inComment = true;
        continue;
      }
      if (chChar == '(') {
        flushWord();
        variationDepth++;
        continue;
      }
      if (chChar == ')') {
        if (variationDepth > 0) variationDepth--;
        continue;
      }
      if (variationDepth > 0) continue;

      if (chChar == ' ' || chChar == '\t' || chChar == '\n') {
        flushWord();
      } else {
        buf.write(chChar);
      }
    }
    flushWord();
    return tokens;
  }

  static void _parseCommentAnnotations(
    String comment,
    int ply,
    Map<int, int> clocksMs,
    Map<int, double> serverEvals,
  ) {
    if (ply <= 0) return;
    final clkMatch =
        RegExp(r'\[%clk\s+(\d+):(\d+):(\d+(?:\.\d+)?)\]').firstMatch(comment);
    if (clkMatch != null) {
      final h = int.tryParse(clkMatch.group(1)!) ?? 0;
      final m = int.tryParse(clkMatch.group(2)!) ?? 0;
      final s = double.tryParse(clkMatch.group(3)!) ?? 0.0;
      clocksMs[ply] = ((h * 3600 + m * 60 + s) * 1000).round();
    }
    final evalMatch =
        RegExp(r'\[%eval\s+([+#-]?\d+(?:\.\d+)?)\]').firstMatch(comment);
    if (evalMatch != null) {
      final val = double.tryParse(evalMatch.group(1)!);
      if (val != null) serverEvals[ply] = val;
    }
  }

  static String _normaliseSanToken(String token) {
    var t = token
        .trim()
        .replaceAll('0-0-0', 'O-O-O')
        .replaceAll('0-0', 'O-O')
        .replaceAll(RegExp(r'[!?]+$'), '');
    // Promotion without '=' e.g. e8Q -> e8=Q
    final promoNoEq = RegExp(r'^([a-h](?:x[a-h])?[18])([QRBN])([+#]?)$').firstMatch(t);
    if (promoNoEq != null) {
      t = '${promoNoEq.group(1)}=${promoNoEq.group(2)}${promoNoEq.group(3)}';
    }
    return t;
  }

  static ch.Move? _findLegalMove(ch.Chess chess, String token) {
    final cleanTarget = token.replaceAll(RegExp(r'[+#]+$'), '');
    final legalMoves = chess.generate_moves();
    for (final m in legalMoves) {
      final san = chess.move_to_san(m);
      final sanClean = san.replaceAll(RegExp(r'[+#]+$'), '');
      if (san == token || sanClean == cleanTarget) {
        return m;
      }
      final uci = '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}';
      if (uci.toLowerCase() == cleanTarget.toLowerCase()) {
        return m;
      }
    }
    return null;
  }

  static SideColor _detectMyColor(
    String white,
    String black,
    List<String> savedUsernames,
  ) {
    for (final handle in savedUsernames) {
      final h = handle.trim().toLowerCase();
      if (h.isEmpty) continue;
      if (black.trim().toLowerCase() == h) return SideColor.b;
      if (white.trim().toLowerCase() == h) return SideColor.w;
    }
    return SideColor.w;
  }

  static String? _extractSourceGameId(
    Map<String, String> headers,
    String source,
  ) {
    final site = headers['Site'] ?? headers['Link'] ?? '';
    if (source == 'lichess' || site.contains('lichess.org/')) {
      final m = RegExp(r'lichess\.org/([A-Za-z0-9]{8})').firstMatch(site);
      if (m != null) return m.group(1);
    }
    if (source == 'chesscom' || site.contains('chess.com/')) {
      final m = RegExp(r'chess\.com/game/(?:live|daily)/(\d+)').firstMatch(site);
      if (m != null) return m.group(1);
    }
    return headers['GameId'];
  }

  static int _parseDateToEpochMs(String dateStr, String? timeStr) {
    try {
      final parts = dateStr.replaceAll('-', '.').split('.');
      final y = int.parse(parts[0]);
      final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 1) : 1;
      final d = parts.length > 2 ? (int.tryParse(parts[2]) ?? 1) : 1;
      var hh = 12, mm = 0, ss = 0;
      if (timeStr != null && timeStr.contains(':')) {
        final tParts = timeStr.split(':');
        hh = int.tryParse(tParts[0]) ?? 12;
        mm = tParts.length > 1 ? (int.tryParse(tParts[1]) ?? 0) : 0;
        ss = tParts.length > 2 ? (int.tryParse(tParts[2]) ?? 0) : 0;
      }
      return DateTime.utc(y, m.clamp(1, 12), d.clamp(1, 31), hh, mm, ss)
          .millisecondsSinceEpoch;
    } catch (_) {
      return DateTime.now().millisecondsSinceEpoch;
    }
  }

  static String _inferTimeClass(String? tc, String? event) {
    final ev = (event ?? '').toLowerCase();
    if (ev.contains('bullet')) return 'bullet';
    if (ev.contains('blitz')) return 'blitz';
    if (ev.contains('rapid')) return 'rapid';
    if (ev.contains('classical') || ev.contains('daily')) return 'classical';
    if (tc == null || tc == '-') return 'rapid';
    final baseSec = int.tryParse(tc.split('+').first) ?? 600;
    if (baseSec < 180) return 'bullet';
    if (baseSec < 600) return 'blitz';
    if (baseSec < 1800) return 'rapid';
    return 'classical';
  }
}
