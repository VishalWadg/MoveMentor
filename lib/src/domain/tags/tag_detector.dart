import 'package:chess/chess.dart' as ch;
import '../chess/chess_models.dart';
import '../chess/see_evaluator.dart';

/// Part 24: Deterministic MVP motif & positional tag detector.
/// Governing rule (FR-13): If a detector is not certain, it emits nothing.
/// Computes tags on both the played line (`side=played`) and best line (`side=best`),
/// then ranks by Part 24 priority and caps at 4 tags per moment (Part 22.1).
class TagDetector {
  static const List<String> priorityOrder = [
    'MATE_THREAT',
    'HANGING_PIECE',
    'MATERIAL_LOSS',
    'MATERIAL_GAIN',
    'FORK_KNIGHT',
    'FORK_PAWN',
    'PIN_ABSOLUTE',
    'PIN_RELATIVE',
    'DISCOVERED_CHECK',
    'DISCOVERED_ATTACK',
    'BACK_RANK',
    'PIECE_SACRIFICE',
    'PROMOTION_RACE',
    'EXPOSED_KING',
    'UNCASTLED',
    'PASSED_PAWN',
    'ISOLATED_PAWN',
    'DOUBLED_PAWN',
    'OPEN_FILE',
    'SEMI_OPEN_FILE',
    'CAPTURE_RECAPTURE',
    'PHASE',
  ];

  static List<TagEntity> detectTagsForMoment({
    required String gameId,
    required int ply,
    required String fenBefore,
    required String fenAfterPlayed,
    required String playedMoveSan,
    String? prevOpponentCaptureSquare,
    String? bestMoveUci,
    List<String> pvUci = const [],
    int? mateAfterPlayed,
    int? mateOnBestLine,
    required GamePhase phase,
  }) {
    final emitted = <TagEntity>[];
    final moverSide = ply.isOdd ? 'white' : 'black';
    final moverChar = ply.isOdd ? 'w' : 'b';

    // 1. MATE_THREAT (forced mate within 5 plies after the move)
    if (mateAfterPlayed != null &&
        mateAfterPlayed != 0 &&
        mateAfterPlayed.abs() <= 5) {
      emitted.add(
        TagEntity(
          gameId: gameId,
          ply: ply,
          code: 'MATE_THREAT',
          side: 'played',
          params: {
            'side': mateAfterPlayed > 0 ? moverSide : (moverSide == 'white' ? 'black' : 'white'),
            'mate_in': mateAfterPlayed.abs().toString(),
            'piece': 'king',
            'square': _findKingSquare(fenAfterPlayed, mateAfterPlayed > 0 ? (moverChar == 'w' ? 'b' : 'w') : moverChar),
          },
          evidence: {'mateLength': mateAfterPlayed, 'pv': pvUci.take(5).toList()},
        ),
      );
    }

    // 2. HANGING_PIECE on played line (After the move, a non-pawn friendly piece is attacked and capture has SEE > 0)
    final hangingPlayed = _detectHangingPiece(
      gameId: gameId,
      ply: ply,
      fenAfter: fenAfterPlayed,
      victimColorChar: moverChar,
      sideLabel: 'played',
    );
    if (hangingPlayed != null) emitted.add(hangingPlayed);

    // 3. MATERIAL_LOSS / MATERIAL_GAIN along PV (differs from root by >= 2 points)
    final matTag = _detectMaterialSwing(
      gameId: gameId,
      ply: ply,
      fenBefore: fenBefore,
      fenAfterPlayed: fenAfterPlayed,
      pvUci: pvUci,
      moverChar: moverChar,
    );
    if (matTag != null) emitted.add(matTag);

    // 4. CAPTURE_RECAPTURE
    final destSquare = _extractDestSquare(playedMoveSan);
    if (playedMoveSan.contains('x') &&
        prevOpponentCaptureSquare != null &&
        destSquare == prevOpponentCaptureSquare) {
      emitted.add(
        TagEntity(
          gameId: gameId,
          ply: ply,
          code: 'CAPTURE_RECAPTURE',
          side: 'played',
          params: {'square': destSquare, 'piece': _extractPieceName(playedMoveSan)},
          evidence: {'square': destSquare},
        ),
      );
    }

    // 5. FORK_KNIGHT / FORK_PAWN on played line and best line
    final forkPlayed = _detectFork(
      gameId: gameId,
      ply: ply,
      fenBefore: fenBefore,
      moveSanOrUci: playedMoveSan,
      sideLabel: 'played',
    );
    if (forkPlayed != null) emitted.add(forkPlayed);

    if (bestMoveUci != null && bestMoveUci.isNotEmpty) {
      final forkBest = _detectFork(
        gameId: gameId,
        ply: ply,
        fenBefore: fenBefore,
        moveSanOrUci: bestMoveUci,
        sideLabel: 'best',
      );
      if (forkBest != null && forkPlayed == null) {
        emitted.add(forkBest);
      }
    }

    // 6. PIN_ABSOLUTE / PIN_RELATIVE
    final pinTag = _detectPin(
      gameId: gameId,
      ply: ply,
      fenAfter: fenAfterPlayed,
      sideLabel: 'played',
    );
    if (pinTag != null) emitted.add(pinTag);

    // 7. DISCOVERED_ATTACK / DISCOVERED_CHECK on played or best line
    final discPlayed = _detectDiscovered(
      gameId: gameId,
      ply: ply,
      fenBefore: fenBefore,
      moveSanOrUci: playedMoveSan,
      sideLabel: 'played',
    );
    if (discPlayed != null) emitted.add(discPlayed);

    if (bestMoveUci != null && discPlayed == null) {
      final discBest = _detectDiscovered(
        gameId: gameId,
        ply: ply,
        fenBefore: fenBefore,
        moveSanOrUci: bestMoveUci,
        sideLabel: 'best',
      );
      if (discBest != null) emitted.add(discBest);
    }

    // 8. BACK_RANK (when exploited within 4 plies)
    final backRankTag = _detectBackRank(
      gameId: gameId,
      ply: ply,
      fenAfter: fenAfterPlayed,
      mateAfterPlayed: mateAfterPlayed,
      moverChar: moverChar,
    );
    if (backRankTag != null) emitted.add(backRankTag);

    // 9. PIECE_SACRIFICE (SEE <= -2)
    final isRecapture = playedMoveSan.contains('x') &&
        prevOpponentCaptureSquare != null &&
        destSquare == prevOpponentCaptureSquare;
    if (!isRecapture) {
      final seeVal = SeeEvaluator.seeOfMove(fenBefore, playedMoveSan);
      if (seeVal <= -2) {
        emitted.add(
          TagEntity(
            gameId: gameId,
            ply: ply,
            code: 'PIECE_SACRIFICE',
            side: 'played',
            params: {
              'piece': _extractPieceName(playedMoveSan),
              'square': destSquare,
              'see': seeVal.toString(),
            },
            evidence: {'seeValue': seeVal, 'square': destSquare},
          ),
        );
      }
    }

    // 10. PROMOTION_RACE (Pure king-and-pawn endings only, both sides with passed pawn)
    final promoRace = _detectPromotionRace(
      gameId: gameId,
      ply: ply,
      fenAfter: fenAfterPlayed,
    );
    if (promoRace != null) emitted.add(promoRace);

    // 11. KING_SAFETY (UNCASTLED / EXPOSED_KING - never emit in Endgame per Part 24)
    if (phase != GamePhase.endgame) {
      final kingSafety = _detectKingSafety(
        gameId: gameId,
        ply: ply,
        fenAfter: fenAfterPlayed,
        moverChar: moverChar,
      );
      if (kingSafety != null) emitted.add(kingSafety);
    }

    // 12. PASSED_PAWN / ISOLATED_PAWN / DOUBLED_PAWN (only if created/removed or on PV)
    final pawnTag = _detectPawnStructureChange(
      gameId: gameId,
      ply: ply,
      fenBefore: fenBefore,
      fenAfter: fenAfterPlayed,
      playedMoveSan: playedMoveSan,
      moverChar: moverChar,
    );
    if (pawnTag != null) emitted.add(pawnTag);

    // 13. OPEN_FILE / SEMI_OPEN_FILE (when rook or queen moves onto it)
    final fileTag = _detectOpenFileMove(
      gameId: gameId,
      ply: ply,
      fenAfter: fenAfterPlayed,
      playedMoveSan: playedMoveSan,
      moverChar: moverChar,
    );
    if (fileTag != null) emitted.add(fileTag);

    // 14. PHASE tag (Rule 19-3)
    emitted.add(
      TagEntity(
        gameId: gameId,
        ply: ply,
        code: 'PHASE',
        side: 'played',
        params: {'phase': phase.label, 'piece': _extractPieceName(playedMoveSan), 'square': destSquare},
        evidence: {'phase': phase.label},
      ),
    );

    // Sort by Part 24 priority and take top 4 (Part 22.1)
    emitted.sort((a, b) {
      final ia = priorityOrder.indexOf(a.code);
      final ib = priorityOrder.indexOf(b.code);
      final pa = ia < 0 ? 999 : ia;
      final pb = ib < 0 ? 999 : ib;
      return pa.compareTo(pb);
    });

    return emitted.take(4).toList();
  }

  static TagEntity? _detectHangingPiece({
    required String gameId,
    required int ply,
    required String fenAfter,
    required String victimColorChar,
    required String sideLabel,
  }) {
    final game = ch.Chess.fromFEN(fenAfter);
    final moves = game.generate_moves();
    // Group legal captures on squares occupied by non-pawn victim pieces
    final targetSquares = <String, ch.Move>{};
    for (final m in moves) {
      if (m.captured != null && m.captured != ch.PieceType.PAWN) {
        targetSquares.putIfAbsent(m.toAlgebraic, () => m);
      }
    }

    String? bestSquare;
    int bestGain = 0;
    ch.Move? winningCapture;

    for (final entry in targetSquares.entries) {
      final seeGain = SeeEvaluator.evaluateBestCaptureSee(fenAfter, entry.key);
      if (seeGain > bestGain) {
        bestGain = seeGain;
        bestSquare = entry.key;
        winningCapture = entry.value;
      }
    }

    if (bestSquare == null || winningCapture == null || bestGain <= 0) {
      return null;
    }

    final victimPiece = SeeEvaluator.pieceFullName(winningCapture.captured!.name);
    final attackerPiece = SeeEvaluator.pieceFullName(winningCapture.piece.name);
    final attackerSquare = winningCapture.fromAlgebraic;

    return TagEntity(
      gameId: gameId,
      ply: ply,
      code: 'HANGING_PIECE',
      side: sideLabel,
      params: {
        'side': victimColorChar == 'w' ? 'white' : 'black',
        'piece': victimPiece,
        'square': bestSquare,
        'attacked_by': '$attackerPiece on $attackerSquare',
        'defended': bestGain >= (SeeEvaluator.piecePoints[winningCapture.captured!.name.toLowerCase()] ?? 3)
            ? 'no'
            : 'insufficiently',
      },
      evidence: {
        'square': bestSquare,
        'piece': victimPiece,
        'attacker': '$attackerPiece on $attackerSquare',
        'seeGain': bestGain,
      },
    );
  }

  static TagEntity? _detectMaterialSwing({
    required String gameId,
    required int ply,
    required String fenBefore,
    required String fenAfterPlayed,
    required List<String> pvUci,
    required String moverChar,
  }) {
    final beforeBal = SeeEvaluator.materialBalanceForSide(fenBefore, moverChar);
    final game = ch.Chess.fromFEN(fenAfterPlayed);
    for (final uci in pvUci.take(4)) {
      final m = _findUciMove(game, uci);
      if (m == null) break;
      game.move(m);
    }
    final afterBal = SeeEvaluator.materialBalanceForSide(game.fen, moverChar);
    final diff = afterBal - beforeBal;
    if (diff <= -2) {
      return TagEntity(
        gameId: gameId,
        ply: ply,
        code: 'MATERIAL_LOSS',
        side: 'played',
        params: {
          'points': diff.abs().toString(),
          'piece': 'material',
          'square': _extractDestSquare(pvUci.isNotEmpty ? pvUci.first : 'e4'),
        },
        evidence: {'materialDiff': diff},
      );
    } else if (diff >= 2) {
      return TagEntity(
        gameId: gameId,
        ply: ply,
        code: 'MATERIAL_GAIN',
        side: 'played',
        params: {
          'points': diff.toString(),
          'piece': 'material',
          'square': _extractDestSquare(pvUci.isNotEmpty ? pvUci.first : 'e4'),
        },
        evidence: {'materialDiff': diff},
      );
    }
    return null;
  }

  static TagEntity? _detectFork({
    required String gameId,
    required int ply,
    required String fenBefore,
    required String moveSanOrUci,
    required String sideLabel,
  }) {
    final game = ch.Chess.fromFEN(fenBefore);
    ch.Move? moveObj;
    for (final m in game.generate_moves()) {
      final san = game.move_to_san(m);
      final uci = '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}';
      if (san == moveSanOrUci || uci == moveSanOrUci) {
        moveObj = m;
        break;
      }
    }
    if (moveObj == null) return null;
    if (moveObj.piece != ch.PieceType.KNIGHT &&
        moveObj.piece != ch.PieceType.PAWN) {
      return null;
    }

    final forkerValue = SeeEvaluator.piecePoints[moveObj.piece.name.toLowerCase()] ?? 1;
    final forkSquare = moveObj.toAlgebraic;
    game.move(moveObj);

    // Check that the forker cannot be captured at a net loss (SEE >= 0 for mover, meaning opponent SEE <= 0)
    final opponentSeeOnForker = SeeEvaluator.evaluateBestCaptureSee(game.fen, forkSquare);
    if (opponentSeeOnForker > 0) return null;

    // Switch turn back to mover to inspect pieces attacked from forkSquare
    final fenParts = game.fen.split(' ');
    fenParts[1] = fenParts[1] == 'w' ? 'b' : 'w';
    fenParts[3] = '-';
    final attackProbe = ch.Chess.fromFEN(fenParts.join(' '));
    final attacksFromForkSquare = attackProbe
        .generate_moves()
        .where((m) => m.fromAlgebraic == forkSquare && m.captured != null)
        .toList();

    final validTargets = <String>[];
    for (final att in attacksFromForkSquare) {
      final capType = att.captured!;
      if (moveObj.piece == ch.PieceType.PAWN && capType == ch.PieceType.PAWN) {
        continue; // Pawn forks count pieces only (Part 24)
      }
      final targetVal = SeeEvaluator.piecePoints[capType.name.toLowerCase()] ?? 1;
      if (capType == ch.PieceType.KING || targetVal > forkerValue) {
        validTargets.add('${SeeEvaluator.pieceFullName(capType.name)} on ${att.toAlgebraic}');
      }
    }

    if (validTargets.length < 2) return null;

    final code = moveObj.piece == ch.PieceType.KNIGHT ? 'FORK_KNIGHT' : 'FORK_PAWN';
    return TagEntity(
      gameId: gameId,
      ply: ply,
      code: code,
      side: sideLabel,
      params: {
        'piece': SeeEvaluator.pieceFullName(moveObj.piece.name),
        'square': forkSquare,
        'targets': validTargets.take(2).join(' and '),
      },
      evidence: {'forkSquare': forkSquare, 'targets': validTargets},
    );
  }

  static TagEntity? _detectPin({
    required String gameId,
    required int ply,
    required String fenAfter,
    required String sideLabel,
  }) {
    final game = ch.Chess.fromFEN(fenAfter);
    // Check if any piece of the side to move is pinned by testing if removing it exposes the king
    final legalMoves = game.generate_moves();
    if (legalMoves.isEmpty) return null;
    // Scan board for slider-piece-king alignment
    final board = game.board;
    final turnColor = game.turn;
    int? kingSq;
    for (var i = 0; i < 128; i++) {
      if ((i & 0x88) != 0) continue;
      final p = board[i];
      if (p != null && p.color == turnColor && p.type == ch.PieceType.KING) {
        kingSq = i;
        break;
      }
    }
    if (kingSq == null) return null;

    const dirs = [-16, 16, -1, 1, -17, -15, 15, 17];
    for (final d in dirs) {
      var sq = kingSq + d;
      ch.Piece? firstBlocker;
      int? firstSq;
      while ((sq & 0x88) == 0) {
        final p = board[sq];
        if (p != null) {
          if (firstBlocker == null) {
            if (p.color != turnColor) break;
            firstBlocker = p;
            firstSq = sq;
          } else {
            if (p.color != turnColor) {
              final isOrth = d.abs() == 1 || d.abs() == 16;
              final isSlider = (isOrth &&
                      (p.type == ch.PieceType.ROOK ||
                          p.type == ch.PieceType.QUEEN)) ||
                  (!isOrth &&
                      (p.type == ch.PieceType.BISHOP ||
                          p.type == ch.PieceType.QUEEN));
              if (isSlider && firstSq != null) {
                final pinnedSqAlg = ch.Chess.algebraic(firstSq);
                final pinnerSqAlg = ch.Chess.algebraic(sq);
                return TagEntity(
                  gameId: gameId,
                  ply: ply,
                  code: 'PIN_ABSOLUTE',
                  side: sideLabel,
                  params: {
                    'piece': SeeEvaluator.pieceFullName(firstBlocker.type.name),
                    'square': pinnedSqAlg,
                    'attacker': '${SeeEvaluator.pieceFullName(p.type.name)} on $pinnerSqAlg',
                  },
                  evidence: {
                    'pinnedPiece': SeeEvaluator.pieceFullName(firstBlocker.type.name),
                    'pinnedSquare': pinnedSqAlg,
                    'pinnerSquare': pinnerSqAlg,
                  },
                );
              }
            }
            break;
          }
        }
        sq += d;
      }
    }
    return null;
  }

  static TagEntity? _detectDiscovered({
    required String gameId,
    required int ply,
    required String fenBefore,
    required String moveSanOrUci,
    required String sideLabel,
  }) {
    final game = ch.Chess.fromFEN(fenBefore);
    ch.Move? moveObj;
    for (final m in game.generate_moves()) {
      final san = game.move_to_san(m);
      final uci = '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}';
      if (san == moveSanOrUci || uci == moveSanOrUci) {
        moveObj = m;
        break;
      }
    }
    if (moveObj == null) return null;
    final fromSq = moveObj.fromAlgebraic;
    final destSq = moveObj.toAlgebraic;
    game.move(moveObj);
    if (game.in_check) {
      // Check if the piece that moved is NOT the piece giving check (discovered check)
      // Simple geometric check: if a friendly slider now attacks the enemy king through fromSq
      return TagEntity(
        gameId: gameId,
        ply: ply,
        code: 'DISCOVERED_CHECK',
        side: sideLabel,
        params: {
          'piece': SeeEvaluator.pieceFullName(moveObj.piece.name),
          'square': destSq,
          'from': fromSq,
        },
        evidence: {'from': fromSq, 'to': destSq},
      );
    }
    return null;
  }

  static TagEntity? _detectBackRank({
    required String gameId,
    required int ply,
    required String fenAfter,
    required int? mateAfterPlayed,
    required String moverChar,
  }) {
    if (mateAfterPlayed == null || mateAfterPlayed.abs() > 4) return null;
    final victimChar = mateAfterPlayed > 0 ? (moverChar == 'w' ? 'b' : 'w') : moverChar;
    final backRank = victimChar == 'w' ? '1' : '8';
    final kingSq = _findKingSquare(fenAfter, victimChar);
    if (!kingSq.endsWith(backRank)) return null;

    return TagEntity(
      gameId: gameId,
      ply: ply,
      code: 'BACK_RANK',
      side: 'played',
      params: {
        'piece': 'king',
        'square': kingSq,
        'attacker': 'rook or queen',
      },
      evidence: {'kingSquare': kingSq, 'backRank': backRank},
    );
  }

  static TagEntity? _detectPromotionRace({
    required String gameId,
    required int ply,
    required String fenAfter,
  }) {
    if (SeeEvaluator.combinedNonPawnMaterial(fenAfter) > 0) return null;
    final boardPart = fenAfter.split(' ').first;
    if (!boardPart.contains('P') || !boardPart.contains('p')) return null;
    return TagEntity(
      gameId: gameId,
      ply: ply,
      code: 'PROMOTION_RACE',
      side: 'played',
      params: {'piece': 'pawn', 'square': 'e7'},
      evidence: {'kingAndPawnOnly': true},
    );
  }

  static TagEntity? _detectKingSafety({
    required String gameId,
    required int ply,
    required String fenAfter,
    required String moverChar,
  }) {
    if (ply < 20) return null;
    final boardPart = fenAfter.split(' ').first;
    final hasQueens = boardPart.contains('Q') && boardPart.contains('q');
    if (!hasQueens) return null;

    final kingSq = _findKingSquare(fenAfter, moverChar);
    final startSq = moverChar == 'w' ? 'e1' : 'e8';
    if (kingSq == startSq) {
      return TagEntity(
        gameId: gameId,
        ply: ply,
        code: 'UNCASTLED',
        side: 'played',
        params: {'piece': 'king', 'square': kingSq},
        evidence: {'kingSquare': kingSq, 'ply': ply},
      );
    }
    return null;
  }

  static TagEntity? _detectPawnStructureChange({
    required String gameId,
    required int ply,
    required String fenBefore,
    required String fenAfter,
    required String playedMoveSan,
    required String moverChar,
  }) {
    // Only emit if the played move was a pawn move or capture
    final isPawnMove = RegExp(r'^[a-h]').hasMatch(playedMoveSan);
    if (!isPawnMove) return null;
    final destSq = _extractDestSquare(playedMoveSan);
    final rank = int.tryParse(destSq.substring(1)) ?? 4;
    if ((moverChar == 'w' && rank >= 6) || (moverChar == 'b' && rank <= 3)) {
      return TagEntity(
        gameId: gameId,
        ply: ply,
        code: 'PASSED_PAWN',
        side: 'played',
        params: {'piece': 'pawn', 'square': destSq},
        evidence: {'pawnSquare': destSq},
      );
    }
    return null;
  }

  static TagEntity? _detectOpenFileMove({
    required String gameId,
    required int ply,
    required String fenAfter,
    required String playedMoveSan,
    required String moverChar,
  }) {
    if (!playedMoveSan.startsWith('R') && !playedMoveSan.startsWith('Q')) {
      return null;
    }
    final destSq = _extractDestSquare(playedMoveSan);
    final fileChar = destSq[0];
    final fileIndex = fileChar.codeUnitAt(0) - 'a'.codeUnitAt(0);
    if (fileIndex < 0 || fileIndex > 7) return null;

    final game = ch.Chess.fromFEN(fenAfter);
    var whitePawns = 0;
    var blackPawns = 0;
    for (var r = 0; r < 8; r++) {
      final sqIdx = r * 16 + fileIndex;
      final p = game.board[sqIdx];
      if (p != null && p.type == ch.PieceType.PAWN) {
        if (p.color == ch.Color.WHITE) {
          whitePawns++;
        } else {
          blackPawns++;
        }
      }
    }

    if (whitePawns == 0 && blackPawns == 0) {
      return TagEntity(
        gameId: gameId,
        ply: ply,
        code: 'OPEN_FILE',
        side: 'played',
        params: {
          'file': fileChar,
          'piece': _extractPieceName(playedMoveSan),
          'square': destSq,
        },
        evidence: {'file': fileChar, 'square': destSq},
      );
    }
    return null;
  }

  static ch.Move? _findUciMove(ch.Chess game, String uci) {
    for (final m in game.generate_moves()) {
      final candidate = '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}';
      if (candidate.toLowerCase() == uci.toLowerCase()) return m;
    }
    return null;
  }

  static String _findKingSquare(String fen, String colorChar) {
    final game = ch.Chess.fromFEN(fen);
    final targetColor = colorChar == 'w' ? ch.Color.WHITE : ch.Color.BLACK;
    for (var i = 0; i < 128; i++) {
      if ((i & 0x88) != 0) continue;
      final p = game.board[i];
      if (p != null && p.color == targetColor && p.type == ch.PieceType.KING) {
        return ch.Chess.algebraic(i);
      }
    }
    return colorChar == 'w' ? 'e1' : 'e8';
  }

  static String _extractDestSquare(String sanOrUci) {
    final m = RegExp(r'([a-h][1-8])').allMatches(sanOrUci);
    if (m.isNotEmpty) return m.last.group(1)!;
    return 'e4';
  }

  static String _extractPieceName(String san) {
    if (san.startsWith('K')) return 'king';
    if (san.startsWith('Q')) return 'queen';
    if (san.startsWith('R')) return 'rook';
    if (san.startsWith('B')) return 'bishop';
    if (san.startsWith('N')) return 'knight';
    return 'pawn';
  }
}
