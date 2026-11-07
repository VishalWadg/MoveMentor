import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/app_state.dart';
import '../../../application/copy_deck.dart';
import '../../../domain/chess/chess_models.dart';
import '../../../domain/coach/coach_contracts.dart';
import '../../widgets/chess_board_widget.dart';

/// Screen 8 & 9: Game Review & Game Summary (matching Part 28.3 Wireframe + Stories F-1, F-2, E-7, I-7).
class GameReviewScreen extends ConsumerStatefulWidget {
  const GameReviewScreen({super.key});

  @override
  ConsumerState<GameReviewScreen> createState() => _GameReviewScreenState();
}

class _GameReviewScreenState extends ConsumerState<GameReviewScreen> {
  int _currentPly = 0;
  bool _flipped = false;
  bool _playingLine = false;
  String? _followUpAnswer;

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(appUiProvider);
    final services = ref.watch(appServicesProvider);
    final gameId = uiState.selectedGameId;
    if (gameId == null) {
      return Center(child: Text(CopyDeck.tr('empty.library')));
    }

    final game = services.storage.getGame(gameId);
    if (game == null) {
      return Center(child: Text(CopyDeck.tr('empty.library')));
    }

    final positions = services.storage.getPositions(gameId);
    final analyses = services.storage.getMoveAnalyses(gameId);
    final summary = services.storage.getGameSummary(gameId);
    final moments = services.storage.getCriticalMoments(gameId);

    final safePly = _currentPly.clamp(
      0,
      positions.isNotEmpty ? positions.length - 1 : 0,
    );
    final currentPos = positions.isNotEmpty ? positions[safePly] : null;
    final currentAnalysis =
        (safePly >= 1 && safePly <= analyses.length) ? analyses[safePly - 1] : null;

    final coachResp = safePly >= 1
        ? services.storage.getExplanation(
            gameId: gameId,
            ply: safePly,
            providerId: uiState.activeProviderId,
            band: uiState.ratingBand,
          )
        : null;

    final myAcc = summary == null
        ? null
        : (game.myColor == SideColor.w ? summary.accWhite : summary.accBlack);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Top Header (Part 28.3 Wireframe: Game vs opponent + Accuracy %)
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                '${game.white} vs ${game.black}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.flip_camera_android),
              tooltip: 'Flip Board',
              onPressed: () => setState(() => _flipped = !_flipped),
            ),
          ],
        ),
        if (myAcc != null) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Chip(
              visualDensity: VisualDensity.compact,
              label: Text(
                'Accuracy ${myAcc.toStringAsFixed(0)}%',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        // Interactive Board with Best-Move Arrow
        if (currentPos != null)
          InteractiveChessBoard(
            fen: currentPos.fen,
            flipped: _flipped,
            lastMoveUci: currentPos.moveUci,
            bestMoveUci: currentAnalysis?.bestMoveUci,
          ),
        const SizedBox(height: 8),
        // Navigation Bar: |< < > >| and [Play line] (Part 28.3)
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.first_page),
                  tooltip: 'First move',
                  onPressed: () => setState(() {
                    _currentPly = 0;
                    _followUpAnswer = null;
                  }),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Previous move',
                  onPressed: () => setState(() {
                    _currentPly = (_currentPly - 1).clamp(0, positions.length - 1);
                    _followUpAnswer = null;
                  }),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Next move',
                  onPressed: () => setState(() {
                    _currentPly = (_currentPly + 1).clamp(0, positions.length - 1);
                    _followUpAnswer = null;
                  }),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.last_page),
                  tooltip: 'Last move',
                  onPressed: () => setState(() {
                    _currentPly = positions.length - 1;
                    _followUpAnswer = null;
                  }),
                ),
              ],
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                // Story I-7: Toggle "My moves / Both sides"
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(uiState.reviewBothSides ? 'Both sides' : 'My moves'),
                  selected: uiState.reviewBothSides,
                  onSelected: (v) =>
                      ref.read(appUiProvider.notifier).setReviewBothSides(v),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _playingLine
                      ? null
                      : () async {
                          setState(() => _playingLine = true);
                          await Future<void>.delayed(const Duration(milliseconds: 300));
                          if (mounted) setState(() => _playingLine = false);
                        },
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Play line'),
                ),
              ],
            ),
          ],
        ),
        // Eval Graph (tap=jump, drag=scrub)
        EvalGraphWidget(
          analyses: analyses,
          currentPly: safePly,
          onSelectPly: (ply) => setState(() {
            _currentPly = ply;
            _followUpAnswer = null;
          }),
        ),
        const SizedBox(height: 8),
        // Critical Moments Carousel (Part 28.3: Moments: ( 12 ) ( 18 ) ...)
        if (moments.isNotEmpty) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text(
                  'Moments: ',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                for (final m in moments)
                  Padding(
                    padding: const EdgeInsets.only(right: 6.0),
                    child: ActionChip(
                      label: Text('Ply ${m.ply} (${m.reason})'),
                      onPressed: () => setState(() {
                        // F-2 AC1: selecting one jumps to the position
                        _currentPly = m.ply;
                        _followUpAnswer = null;
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        // Coach Commentary Panel (Part 28.3)
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (currentAnalysis != null)
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MoveBadgeChip(classification: currentAnalysis.label),
                          const SizedBox(width: 8),
                          Text(
                            currentPos?.moveSan ?? '',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          coachResp?.isFallback == true
                              ? CopyDeck.tr('coach.template_marker')
                              : '[${uiState.activeProviderId}]',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          'Select a move or run analysis to see coaching.',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          '[${uiState.activeProviderId}]',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                if (coachResp != null) ...[
                  Text(coachResp.coachCommentary),
                  const SizedBox(height: 6),
                  Text(
                    'Better idea: ${coachResp.betterIdea}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Lesson: ${coachResp.lesson}',
                    style: TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                  if (coachResp.isFallback)
                    TextButton.icon(
                      onPressed: () => _explainCurrentPlyOnDemand(gameId, safePly),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: Text(
                        CopyDeck.tr(
                          'coach.retry',
                          {'provider': uiState.activeProviderId},
                        ),
                      ),
                    ),
                  // Story E-7: Follow-up questions constrained to moment facts
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ActionChip(
                        label: const Text('Explain simpler'),
                        onPressed: () => setState(() {
                          _followUpAnswer =
                              'Simpler: ${coachResp.tacticalSummary} ${coachResp.lesson}';
                        }),
                      ),
                      ActionChip(
                        label: const Text('What was the idea of the best move?'),
                        onPressed: () => setState(() {
                          _followUpAnswer = coachResp.betterIdea;
                        }),
                      ),
                    ],
                  ),
                  if (_followUpAnswer != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _followUpAnswer!,
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ],
                ] else if (currentAnalysis != null) ...[
                  Text(
                    'Win probability: ${currentAnalysis.winBefore.toStringAsFixed(1)}% → ${currentAnalysis.winAfter.toStringAsFixed(1)}% (drop ${currentAnalysis.deltaW.toStringAsFixed(1)}%)',
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _explainCurrentPlyOnDemand(gameId, safePly),
                    icon: const Icon(Icons.psychology_outlined),
                    label: const Text('Explain this move with AI Coach'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Horizontal Move List with Badges
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var p = 1; p < positions.length; p++)
                Padding(
                  padding: const EdgeInsets.only(right: 4.0),
                  child: ChoiceChip(
                    selected: safePly == p,
                    label: Text(
                      '${p.isOdd ? "${(p + 1) ~/ 2}." : ""}${positions[p].moveSan ?? ""}',
                    ),
                    onSelected: (_) => setState(() {
                      _currentPly = p;
                      _followUpAnswer = null;
                    }),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _explainCurrentPlyOnDemand(String gameId, int ply) async {
    final services = ref.read(appServicesProvider);
    final uiState = ref.read(appUiProvider);
    final game = services.storage.getGame(gameId);
    final positions = services.storage.getPositions(gameId);
    final analyses = services.storage.getMoveAnalyses(gameId);
    if (game == null || ply < 1 || ply > analyses.length) return;

    final ma = analyses[ply - 1];
    final posBefore = positions[ply - 1];
    final posAfter = positions[ply];
    final tags = services.storage.getGameTags(gameId, ply: ply);

    final req = CoachRequest(
      gameId: gameId,
      ratingBand: uiState.ratingBand,
      userColor: game.myColor,
      ply: ply,
      fen: posBefore.fen,
      moveSan: posAfter.moveSan ?? '',
      classification: ma.label,
      winBefore: ma.winBefore,
      winAfter: ma.winAfter,
      deltaW: ma.deltaW,
      bestMoveSan: ma.bestMoveSan ?? (posAfter.moveSan ?? ''),
      bestLineSan: [ma.bestMoveSan ?? (posAfter.moveSan ?? '')],
      phase: ma.phase,
      tags: tags,
    );

    await services.providerRegistry.explainMomentWithFallback(req);
    if (mounted) setState(() {});
  }
}
