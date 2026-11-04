import 'dart:convert';
import 'package:chess/chess.dart' as ch;
import 'package:crypto/crypto.dart';

/// Part 21 & Part 9.3: Deterministic FEN normalisation, position_key, moves_hash, and fingerprint.
class FenNormalizer {
  static const String startFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  /// Normalised FEN drops both move counters (halfmove & fullmove) and keeps the
  /// en-passant square ONLY if a legal en-passant capture exists in the position.
  static String normaliseFen(String fen) {
    final parts = fen.trim().split(RegExp(r'\s+'));
    if (parts.length < 4) return fen.trim();
    final boardPart = parts[0];
    final turnPart = parts[1];
    final castlingPart = parts[2];
    var epSquare = parts[3];

    if (epSquare != '-') {
      final board = ch.Chess.fromFEN(fen);
      final legalMoves = board.generate_moves();
      final hasEpCapture = legalMoves.any(
        (m) => (m.flags & ch.Chess.BITS_EP_CAPTURE) != 0,
      );
      if (!hasEpCapture) {
        epSquare = '-';
      }
    }
    return '$boardPart $turnPart $castlingPart $epSquare';
  }

  /// Part 27.1: EPD key for opening lookup (4 fields of FEN).
  static String toEpd(String fen) => normaliseFen(fen);

  /// Part 21: `position_key = sha1(normalised_fen + '|' + engine_version + '|' + settings_hash)`
  static String computePositionKey({
    required String fen,
    required String engineVersion,
    required String settingsHash,
  }) {
    final norm = normaliseFen(fen);
    final payload = '$norm|$engineVersion|$settingsHash';
    return sha1.convert(utf8.encode(payload)).toString();
  }

  /// Part 21: `moves_hash = sha1(normalised SAN list)`
  static String computeMovesHash(List<String> movesSan) {
    final normalised = movesSan
        .map((m) => m.trim().replaceAll(RegExp(r'[!?+#]+$'), ''))
        .where((m) => m.isNotEmpty)
        .join(' ');
    return sha1.convert(utf8.encode(normalised)).toString();
  }

  /// Part 9.3: Stable game fingerprint from normalised headers + normalised SAN list.
  static String computeFingerprint({
    required String white,
    required String black,
    required String date,
    required String result,
    String round = '',
    String event = '',
    String site = '',
    required List<String> movesSan,
  }) {
    final headerKey = [
      white.trim().toLowerCase(),
      black.trim().toLowerCase(),
      date.trim().toLowerCase(),
      result.trim().toLowerCase(),
      round.trim().toLowerCase(),
      event.trim().toLowerCase(),
      site.trim().toLowerCase(),
    ].join('|');
    final movesPart = movesSan
        .map((m) => m.trim())
        .where((m) => m.isNotEmpty)
        .join(' ');
    return sha1.convert(utf8.encode('$headerKey||$movesPart')).toString();
  }
}

/// Part 25: Converts SAN move notation into natural English words (`"Knight to f3"`).
/// Covered by unit tests for castling, promotion, captures, and checks.
class SanWords {
  static const Map<String, String> _pieceNames = {
    'K': 'King',
    'Q': 'Queen',
    'R': 'Rook',
    'B': 'Bishop',
    'N': 'Knight',
  };

  static String sanToWords(String san) {
    var clean = san.trim();
    if (clean.isEmpty) return 'a solid move';

    final isMate = clean.endsWith('#');
    final isCheck = clean.endsWith('+');
    clean = clean.replaceAll(RegExp(r'[+#!?]+$'), '');

    String suffix = '';
    if (isMate) {
      suffix = ' delivering checkmate';
    } else if (isCheck) {
      suffix = ' with check';
    }

    if (clean == 'O-O' || clean == '0-0') {
      return 'castling kingside$suffix';
    }
    if (clean == 'O-O-O' || clean == '0-0-0') {
      return 'castling queenside$suffix';
    }

    // Check promotion e.g. e8=Q or exd8=N or e8Q
    String? promoPiece;
    final promoMatch = RegExp(r'=?([QRBN])$').firstMatch(clean);
    if (promoMatch != null && clean.length >= 3) {
      final char = promoMatch.group(1)!;
      promoPiece = _pieceNames[char] ?? 'Queen';
      clean = clean.substring(0, promoMatch.start);
    }

    final isCapture = clean.contains('x');
    final destMatch = RegExp(r'([a-h][1-8])$').firstMatch(clean);
    final destSquare = destMatch?.group(1) ?? clean;

    String pieceWord = 'Pawn';
    if (clean.isNotEmpty && _pieceNames.containsKey(clean[0])) {
      pieceWord = _pieceNames[clean[0]]!;
    }

    final action = isCapture ? 'captures on $destSquare' : 'to $destSquare';
    final promoText =
        promoPiece != null ? ' promoting to $promoPiece' : '';
    return '$pieceWord $action$promoText$suffix';
  }
}
