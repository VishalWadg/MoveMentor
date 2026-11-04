import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../domain/chess/chess_models.dart';
import '../../domain/chess/fen_normalizer.dart';
import '../../domain/coach/coach_contracts.dart';
import '../../ports/ports.dart';

/// Part 25: Compositional Template Coach Provider (`template`).
/// Composes four parts:
/// - S1 What happened: keyed by tag (15 MVP tags x 3 variants = 45 strings + generic fallbacks)
/// - S2 Why it matters: keyed by classification group x band (4) x 3 variants = 60 strings
/// - S3 Better idea: 1 pattern per band using `{best_words}` (`SanWords.sanToWords`) = 4 strings
/// - S4 Lesson: keyed by tag (15) x band (4) = 60 strings
/// Deterministic variant selection: `hash(gameId + ply + partName) mod variantCount`.
class TemplateCoachProvider implements ExplanationProvider {
  @override
  String get id => 'template';

  @override
  ProviderCapabilities get caps => const ProviderCapabilities(
        supportsStreaming: true,
        maxContextTokens: 4096,
        supportsJsonMode: true,
        supportsGrammar: true,
        isRemote: false,
      );

  /// S1: 15 MVP tags x 3 variants = 45 strings (Part 25).
  static const Map<String, List<String>> s1ByTag = {
    'HANGING_PIECE': [
      'Your {piece} on {square} could be captured by the {attacker}.',
      'Moving to {square} left the {piece} exposed to the {attacker}.',
      'The {piece} on {square} stands undefended against the {attacker}.',
    ],
    'MATE_THREAT': [
      'This position allows a forced checkmate sequence against the {piece} on {square}.',
      'A direct mating net now targets the {piece} near {square}.',
      'Forced mate is on the board starting against {square}.',
    ],
    'MATERIAL_LOSS': [
      'This exchange sequence drops material around {square}.',
      'After the forced replies on {square}, your side comes out down material.',
      'Trading on {square} loses material once the tactic settles.',
    ],
    'MATERIAL_GAIN': [
      'This continuation wins material cleanly around {square}.',
      'Your sequence on {square} comes out ahead in material.',
      'The tactical exchange on {square} captures high-value material.',
    ],
    'FORK_KNIGHT': [
      'A knight move to {square} attacks {targets} at once.',
      'The knight on {square} creates a double attack against {targets}.',
      'Landing the knight on {square} forks {targets}.',
    ],
    'FORK_PAWN': [
      'Advancing the pawn to {square} forks {targets}.',
      'The pawn push to {square} attacks two enemy pieces ({targets}) simultaneously.',
      'A pawn fork on {square} challenges {targets} at the same time.',
    ],
    'PIN_ABSOLUTE': [
      'The {piece} on {square} is pinned to the king by the {attacker}.',
      'Because of the {attacker}, the {piece} on {square} cannot legally move.',
      'An absolute pin along the line freezes the {piece} on {square}.',
    ],
    'PIN_RELATIVE': [
      'Moving the {piece} from {square} would expose a more valuable piece behind it.',
      'The {piece} on {square} is under a relative pin from the {attacker}.',
      'Line pressure pins the {piece} on {square} to a high-value target.',
    ],
    'DISCOVERED_CHECK': [
      'Moving the {piece} to {square} unleashes a discovered check.',
      'Stepping to {square} opens the line for a discovered check.',
      'Clearing the square with the {piece} reveals a check against the king.',
    ],
    'DISCOVERED_ATTACK': [
      'Moving the {piece} to {square} uncovers a discovered attack.',
      'Vacating the line with the {piece} reveals an attack on {square}.',
      'A discovered attack opens up as the {piece} moves to {square}.',
    ],
    'BACK_RANK': [
      'The back rank around {square} is vulnerable to a rook or queen check.',
      'With no flight squares in front of {square}, the back rank is exposed.',
      'A back-rank tactic targets the king trapped on {square}.',
    ],
    'PIECE_SACRIFICE': [
      'Your {piece} sacrifices material on {square} to seize the initiative.',
      'Giving up the {piece} on {square} invests material for attacking lines.',
      'This move offers a {piece} sacrifice on {square}.',
    ],
    'PROMOTION_RACE': [
      'The passed pawn near {square} enters a direct promotion race.',
      'Every tempo counts as the {piece} on {square} races to promote.',
      'In this king-and-pawn ending, the race toward {square} decides the game.',
    ],
    'UNCASTLED': [
      'The {piece} remains uncastled on {square} with central lines opening.',
      'Leaving the {piece} on {square} delays king safety in the middlegame.',
      'With queens still on the board, the {piece} on {square} needs shelter.',
    ],
    'OPEN_FILE': [
      'The {piece} claims control of the open file via {square}.',
      'Placing the {piece} on {square} contests the open file.',
      'Open-file activity on {square} increases long-range pressure.',
    ],
  };

  /// Generic S1 fallback per classification when no specific tactic tag applies.
  static const Map<String, List<String>> s1GenericByClass = {
    'Brilliant': [
      'You played a resourceful tactical sacrifice on {square}.',
      'This creative move on {square} finds the sharpest continuation.',
      'Your move to {square} unlocks a deep tactical resource.',
    ],
    'Great': [
      'You found the critical move to {square} when alternatives fell short.',
      'Playing to {square} was the key move to hold the balance.',
      'Your choice on {square} accurately navigated a sharp position.',
    ],
    'Best': [
      'Playing the {piece} to {square} matched the engine top choice.',
      'Moving to {square} kept your position well coordinated.',
      'Your move on {square} maintained maximum pressure.',
    ],
    'Inaccuracy': [
      'Moving to {square} was slightly passive and ceded a small edge.',
      'This move on {square} allowed your opponent easier development.',
      'Playing to {square} missed a slightly more active continuation.',
    ],
    'Mistake': [
      'This move gave your opponent more than it should have.',
      'Playing to {square} weakened your coordination and lost ground.',
      'Moving the {piece} to {square} overlooked an important tactical reply.',
    ],
    'Blunder': [
      'This move gave your opponent more than it should have.',
      'Moving to {square} allowed an immediate punishing reply.',
      'Playing the {piece} to {square} changed the evaluation sharply.',
    ],
  };

  /// S2 Why it matters: 5 classification groups x 4 bands x 3 variants = 60 strings.
  static const Map<String, List<String>> s2ByGroupAndBand = {
    'Brilliant|Novice': [
      'You gave up material on purpose, and the engine confirms the idea works.',
      'Even though it looks risky, this sacrifice wins back more very soon.',
      'Brave move: the attack you get is stronger than the piece you gave up.',
    ],
    'Brilliant|Intermediate': [
      'You gave up material on purpose, and the engine confirms the idea works.',
      'The sacrifice generates decisive tactical compensation along the forcing line.',
      'Dynamic initiative and open lines outweigh the invested material here.',
    ],
    'Brilliant|Advanced': [
      'You gave up material on purpose, and the engine confirms the idea works.',
      'Concrete calculation validates the sacrifice, seizing lasting initiative.',
      'No quiet alternative keeps the same advantage as this sacrificial break.',
    ],
    'Brilliant|Master': [
      'You gave up material on purpose, and the engine confirms the idea works.',
      'Only forcing sacrificial resource that maintains the evaluation.',
      'Sound material investment backed by concrete tactical refutation of defences.',
    ],
    'Great|Novice': [
      'That was the only move that kept your pieces safe and active.',
      'Finding that move stopped your opponent from taking over the game.',
      'Great job spotting the one move that keeps your side in good shape.',
    ],
    'Great|Intermediate': [
      'Every other candidate lost significant ground, making this an essential find.',
      'Spotting this critical resource preserved your tactical coordination.',
      'This accurate choice separated a playable position from a difficult defence.',
    ],
    'Great|Advanced': [
      'Finding the sole accurate continuation maintained the dynamic balance.',
      'All secondary alternatives conceded a large swing in win probability.',
      'Precise calculation kept the initiative under high board volatility.',
    ],
    'Great|Master': [
      'Found the critical only-move resource with >15% margin over second-best.',
      'Accurate conversion move under high tactical tension.',
      'Essential move-order accuracy preserving the evaluation.',
    ],
    'Inaccuracy|Novice': [
      'Your position is still okay, but another move made things easier.',
      'It gives the other side extra time to bring their pieces out.',
      'A small slip that lets your opponent get a bit more comfortable.',
    ],
    'Inaccuracy|Intermediate': [
      'This loses a tempo and lets the opponent coordinate more freely.',
      'A slightly imprecise choice that surrenders part of your initiative.',
      'More active piece placement was available to keep the pressure on.',
    ],
    'Inaccuracy|Advanced': [
      'This softens pressure on key squares and allows simplifying equality.',
      'Suboptimal piece activity gives the opponent time to consolidate.',
      'Cedes a modest equity edge by missing the most forcing continuation.',
    ],
    'Inaccuracy|Master': [
      'Slight move-order inaccuracy allowing counterplay.',
      'Concedes initiative by delaying the thematic break.',
      'Permits easier defensive consolidation than the principal line.',
    ],
    'Mistake|Novice': [
      'That lets your opponent win a piece or get a strong attack.',
      'After this move, your pieces are much harder to defend.',
      'This gives away a big advantage that is tough to recover.',
    ],
    'Mistake|Intermediate': [
      'This tactical oversight hands over a clear advantage.',
      'Leaving that weakness unguarded lets the opponent seize control.',
      'The resulting position drops significant win equity and tempo.',
    ],
    'Mistake|Advanced': [
      'This concession compromises your structure and tactical stability.',
      'Missing the opponent reply causes a major swing in win probability.',
      'Allows a forcing sequence that damages your coordination.',
    ],
    'Mistake|Master': [
      'Serious evaluation drop allowing immediate tactical exploitation.',
      'Fails to neutralise the opponent threat before committing material.',
      'Concedes a clear advantage through imprecise calculation.',
    ],
    'Blunder|Novice': [
      'That loses material that is hard to win back.',
      'Your opponent can now capture for free or threaten checkmate.',
      'This turns a playable game into a very difficult position right away.',
    ],
    'Blunder|Intermediate': [
      'That loses material that is hard to win back.',
      'This blunder overlooks a direct tactical refutation by the opponent.',
      'The move causes a decisive drop in win probability.',
    ],
    'Blunder|Advanced': [
      'This concedes a decisive material or positional advantage.',
      'Overlooking the forcing refutation collapses the defensive structure.',
      'A critical tactical error that turns the game state immediately.',
    ],
    'Blunder|Master': [
      'This concedes a decisive material or positional advantage.',
      'Direct tactical oversight allowing a winning forcing continuation.',
      'Collapses win equity by allowing an unanswerable refutation.',
    ],
  };

  /// S3 Better idea: 1 pattern per band using `{best_words}`.
  static const Map<RatingBand, String> s3ByBand = {
    RatingBand.novice: 'A safer idea was {best_words} ({best_san}).',
    RatingBand.intermediate: 'A stronger continuation was {best_words} ({best_san}).',
    RatingBand.advanced: 'The engine prefers {best_words} ({best_san}) to keep activity.',
    RatingBand.master: 'Best was {best_words} ({best_san}).',
  };

  /// S4 Lesson: 15 tags x 4 bands = 60 strings (Part 25).
  static const Map<String, Map<RatingBand, String>> s4ByTagAndBand = {
    'HANGING_PIECE': {
      RatingBand.novice: 'Before every move, check which of your pieces can be captured.',
      RatingBand.intermediate: 'Verify that every moved or uncovered piece has adequate defenders.',
      RatingBand.advanced: 'Audit loose pieces and SEE exchanges before committing to a line.',
      RatingBand.master: 'Recheck tactical loose-piece vulnerability at the end of the line.',
    },
    'MATE_THREAT': {
      RatingBand.novice: 'Always watch for checks that trap the king with no escape.',
      RatingBand.intermediate: 'Check forcing mating patterns around the king before moving.',
      RatingBand.advanced: 'Prioritise king-zone forcing checks over material considerations.',
      RatingBand.master: 'Verify forcing mate sequences before quiet positional play.',
    },
    'MATERIAL_LOSS': {
      RatingBand.novice: 'Count how many attackers and defenders are on a square before trading.',
      RatingBand.intermediate: 'Calculate the full capture sequence until the position is quiet.',
      RatingBand.advanced: 'Evaluate the resulting material balance at the end of forced exchanges.',
      RatingBand.master: 'Extend exchange calculation to the first quiet position.',
    },
    'MATERIAL_GAIN': {
      RatingBand.novice: 'Look for safe captures that win higher-value pieces.',
      RatingBand.intermediate: 'Convert tactical targets cleanly when ahead in attackers.',
      RatingBand.advanced: 'Cash in tactical pressure when the resulting simplification is winning.',
      RatingBand.master: 'Convert concrete material gains without allowing counterplay.',
    },
    'FORK_KNIGHT': {
      RatingBand.novice: 'Look for knight jumps that attack two enemy pieces at once.',
      RatingBand.intermediate: 'Scan for undefended squares where a knight can fork two targets.',
      RatingBand.advanced: 'Exploit loose piece geometry with knight double attacks.',
      RatingBand.master: 'Track knight fork motifs on unguarded dark/light complexes.',
    },
    'FORK_PAWN': {
      RatingBand.novice: 'Watch for pawn pushes that attack two pieces side by side.',
      RatingBand.intermediate: 'Avoid placing two pieces on adjacent squares in front of enemy pawns.',
      RatingBand.advanced: 'Use central pawn advances to gain tempo via double attacks.',
      RatingBand.master: 'Prevent and exploit tactical pawn forks in compact structures.',
    },
    'PIN_ABSOLUTE': {
      RatingBand.novice: 'Remember that a piece shielding your king cannot move out of line.',
      RatingBand.intermediate: 'Pile pressure onto pinned pieces that cannot legally move.',
      RatingBand.advanced: 'Exploit absolute pins by attacking the immobilised defender with pawns.',
      RatingBand.master: 'Maximise pressure along the pin ray before resolving tension.',
    },
    'PIN_RELATIVE': {
      RatingBand.novice: 'Be careful moving a piece when a stronger piece sits right behind it.',
      RatingBand.intermediate: 'Break relative pins safely or avoid aligning high-value pieces.',
      RatingBand.advanced: 'Evaluate whether a relative pin can be tactically broken with tempo.',
      RatingBand.master: 'Account for relative pin geometry in tactical move orders.',
    },
    'DISCOVERED_CHECK': {
      RatingBand.novice: 'When one piece moves out of the way, check if a piece behind it attacks the king.',
      RatingBand.intermediate: 'Use discovered checks to win material with a free tempo.',
      RatingBand.advanced: 'Align sliders with the enemy king to set up discovered check tactics.',
      RatingBand.master: 'Exploit slider alignments via forcing discovered checks.',
    },
    'DISCOVERED_ATTACK': {
      RatingBand.novice: 'Watch what lines open up when a piece steps off a file or diagonal.',
      RatingBand.intermediate: 'Create double threats by combining a move with an uncovered attack.',
      RatingBand.advanced: 'Coordinate battery pieces to generate discovered tactical threats.',
      RatingBand.master: 'Use discovered attacks to force favourable move-order concessions.',
    },
    'BACK_RANK': {
      RatingBand.novice: 'Give your castled king a breathing square so rooks cannot mate on the back row.',
      RatingBand.intermediate: 'Create luft or keep a defender covering the back rank.',
      RatingBand.advanced: 'Monitor back-rank deflection motifs when heavy pieces remain.',
      RatingBand.master: 'Factor back-rank overload into heavy-piece endgame calculation.',
    },
    'PIECE_SACRIFICE': {
      RatingBand.novice: 'Only give up a piece when you see a clear checkmate or win it right back.',
      RatingBand.intermediate: 'Ensure sacrifices lead to concrete forcing threats or material recovery.',
      RatingBand.advanced: 'Weigh sacrificial initiative against concrete defensive resources.',
      RatingBand.master: 'Validate sacrifices to a forced conclusion or clear compensation.',
    },
    'PROMOTION_RACE': {
      RatingBand.novice: 'Push passed pawns quickly and use the rule of the square.',
      RatingBand.intermediate: 'Count tempos carefully in king-and-pawn promotion races.',
      RatingBand.advanced: 'Calculate queening with check and shoulder-charging paths.',
      RatingBand.master: 'Compute exact tempo parity and queening squares in pawn races.',
    },
    'UNCASTLED': {
      RatingBand.novice: 'Castle early so your king is safe behind pawns.',
      RatingBand.intermediate: 'Prioritise castling before opening central files with queens on.',
      RatingBand.advanced: 'Do not delay king safety when the centre becomes dynamic.',
      RatingBand.master: 'Resolve king safety before initiating central complications.',
    },
    'OPEN_FILE': {
      RatingBand.novice: 'Put your rooks on files with no pawns blocking them.',
      RatingBand.intermediate: 'Contest open files with rooks and queens to reach the seventh rank.',
      RatingBand.advanced: 'Seize open files to penetrate into the opponent camp.',
      RatingBand.master: 'Convert open-file control into seventh/eighth-rank infiltration.',
    },
  };

  @override
  Future<ProviderStatus> check() async => const ProviderStatus(
        status: ProviderStatusType.ready,
        message: 'Template Coach ready offline.',
      );

  @override
  Stream<CoachChunk> explain(
    CoachRequest req, {
    CancelToken? cancel,
  }) async* {
    if (cancel?.isCancelled == true) return;
    final response = buildDeterministicResponse(req);
    yield CoachChunk(
      deltaText: response.coachCommentary,
      finalResponse: response,
      isDone: true,
    );
  }

  CoachResponse buildDeterministicResponse(
    CoachRequest req, {
    bool isFallback = false,
  }) {
    final primaryTag = req.tags.isNotEmpty ? req.tags.first : null;
    final tagCode = primaryTag?.code ?? 'PHASE';

    // Fill slots from tag params or request defaults (never leave unfilled `{slot}`)
    final piece = primaryTag?.params['piece'] ?? _pieceFromSan(req.moveSan);
    final square = primaryTag?.params['square'] ?? _squareFromSan(req.moveSan);
    final attacker =
        primaryTag?.params['attacked_by'] ??
        primaryTag?.params['attacker'] ??
        'opponent piece';
    final targets =
        primaryTag?.params['targets'] ?? 'two enemy pieces';
    final bestSan = req.bestMoveSan.isNotEmpty ? req.bestMoveSan : req.moveSan;
    final bestWords = SanWords.sanToWords(bestSan);

    // S1 selection
    final s1Pool = s1ByTag[tagCode] ??
        s1GenericByClass[req.classification.label] ??
        s1GenericByClass['Mistake']!;
    final s1Idx = _deterministicVariantIndex(
      req.gameId,
      req.ply,
      'S1',
      s1Pool.length,
    );
    var s1Text = primaryTag != null &&
            primaryTag.side == 'best' &&
            tagCode == 'FORK_KNIGHT'
        ? 'A knight move to {square} would have attacked {targets} at once.'
        : s1Pool[s1Idx];
    s1Text = _fillSlots(
      s1Text,
      piece: piece,
      square: square,
      attacker: attacker,
      targets: targets,
      bestWords: bestWords,
      bestSan: bestSan,
    );

    // S2 selection
    final groupLabel = _mapClassGroup(req.classification);
    final s2Key = '$groupLabel|${req.ratingBand.label}';
    final s2Pool = s2ByGroupAndBand[s2Key] ??
        s2ByGroupAndBand['Mistake|Novice']!;
    final s2Idx = _deterministicVariantIndex(
      req.gameId,
      req.ply,
      'S2',
      s2Pool.length,
    );
    final s2Text = _fillSlots(
      s2Pool[s2Idx],
      piece: piece,
      square: square,
      attacker: attacker,
      targets: targets,
      bestWords: bestWords,
      bestSan: bestSan,
    );

    // S3 Better idea
    final s3Template =
        s3ByBand[req.ratingBand] ?? s3ByBand[RatingBand.novice]!;
    final s3Text = req.classification.isPositive &&
            req.bestMoveSan == req.moveSan
        ? 'Playing $bestWords ($bestSan) was the engine top continuation.'
        : _fillSlots(
            s3Template,
            piece: piece,
            square: square,
            attacker: attacker,
            targets: targets,
            bestWords: bestWords,
            bestSan: bestSan,
          );

    // S4 Lesson
    final s4Map =
        s4ByTagAndBand[tagCode] ?? s4ByTagAndBand['HANGING_PIECE']!;
    final s4Text = _fillSlots(
      s4Map[req.ratingBand] ?? s4Map[RatingBand.novice]!,
      piece: piece,
      square: square,
      attacker: attacker,
      targets: targets,
      bestWords: bestWords,
      bestSan: bestSan,
    );

    final includeS3InCommentary = bestSan != req.moveSan;
    final commentary = includeS3InCommentary
        ? '$s1Text $s2Text $s3Text'
        : '$s1Text $s2Text';

    final debugTrace =
        'TemplateCoach[tag=$tagCode(${primaryTag?.ruleVersion ?? "v1.0"}), group=$groupLabel, band=${req.ratingBand.label}, s1=$s1Idx, s2=$s2Idx]';

    return CoachResponse(
      move: req.moveSan,
      classification: req.classification.label,
      winEquityDrop: double.parse(req.deltaW.toStringAsFixed(1)),
      tacticalSummary: _truncate(s1Text, 160),
      coachCommentary: _truncate(commentary, 480),
      betterIdea: _truncate(s3Text, 160),
      lesson: _truncate(s4Text, 100),
      providerId: id,
      isFallback: isFallback,
      debugReason: debugTrace,
    );
  }

  /// Part 25: `hash(gameId + ply + partName) mod variantCount` so replay shows identical text.
  static int _deterministicVariantIndex(
    String gameId,
    int ply,
    String partName,
    int variantCount,
  ) {
    if (variantCount <= 1) return 0;
    final digest = sha1.convert(utf8.encode('$gameId|$ply|$partName')).bytes;
    final numVal = (digest[0] << 8) | digest[1];
    return numVal % variantCount;
  }

  static String _mapClassGroup(MoveClassification c) {
    switch (c) {
      case MoveClassification.brilliant:
        return 'Brilliant';
      case MoveClassification.great:
      case MoveClassification.best:
      case MoveClassification.excellent:
      case MoveClassification.good:
      case MoveClassification.book:
        return 'Great';
      case MoveClassification.inaccuracy:
        return 'Inaccuracy';
      case MoveClassification.mistake:
        return 'Mistake';
      case MoveClassification.blunder:
        return 'Blunder';
    }
  }

  static String _fillSlots(
    String template, {
    required String piece,
    required String square,
    required String attacker,
    required String targets,
    required String bestWords,
    required String bestSan,
  }) {
    return template
        .replaceAll('{piece}', piece)
        .replaceAll('{square}', square)
        .replaceAll('{attacker}', attacker)
        .replaceAll('{targets}', targets)
        .replaceAll('{best_words}', bestWords)
        .replaceAll('{best_san}', bestSan);
  }

  static String _pieceFromSan(String san) {
    if (san.startsWith('K')) return 'king';
    if (san.startsWith('Q')) return 'queen';
    if (san.startsWith('R')) return 'rook';
    if (san.startsWith('B')) return 'bishop';
    if (san.startsWith('N')) return 'knight';
    return 'pawn';
  }

  static String _squareFromSan(String san) {
    final m = RegExp(r'([a-h][1-8])').allMatches(san);
    if (m.isNotEmpty) return m.last.group(1)!;
    return 'e4';
  }

  static String _truncate(String s, int maxLen) =>
      s.length <= maxLen ? s : '${s.substring(0, maxLen - 3)}...';

  @override
  Future<void> dispose() async {}
}
