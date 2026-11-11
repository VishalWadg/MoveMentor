/// An entry in the opening book.
class OpeningEntry {
  final String eco;
  final String name;
  final String? variation;
  final String epd;

  const OpeningEntry({
    required this.eco,
    required this.name,
    this.variation,
    required this.epd,
  });

  String get fullName => variation != null && variation!.isNotEmpty
      ? '$name: $variation'
      : name;
}

/// Port for position-keyed opening books.
///
/// SPEC RULES:
/// - Use EPD position matching, not move-order matching.
/// - EPD: Piece placement, side to move, castling rights, and en passant square.
abstract class OpeningBookPort {
  /// Extracts the standard EPD (first 4 fields of FEN) for position-keyed lookup.
  static String fenToEpd(String fen) {
    final parts = fen.trim().split(RegExp(r'\s+'));
    if (parts.length >= 4) {
      return '${parts[0]} ${parts[1]} ${parts[2]} ${parts[3]}';
    }
    return fen.trim();
  }

  /// Looks up an opening by exact EPD.
  OpeningEntry? lookupByEpd(String epd);

  /// Looks up an opening by full FEN (automatically converts to EPD).
  OpeningEntry? lookupByFen(String fen) {
    return lookupByEpd(fenToEpd(fen));
  }
}
