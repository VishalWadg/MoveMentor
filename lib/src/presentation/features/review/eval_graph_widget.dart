import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../domain/chess/chess_models.dart';

/// Story F-1 AC3: Interactive Win% Evaluation Graph powered by fl_chart.
///
/// Features:
/// - Win probability curve (0% to 100%) with midline at 50%.
/// - Vertical marker line at current ply.
/// - Interactive touch & horizontal drag scrubbing that triggers [onSelectPly] / [onPlySelected] in real time.
class EvalGraphWidget extends StatefulWidget {
  final List<MoveAnalysisEntity> analyses;
  final int currentPly;
  final ValueChanged<int>? onSelectPly;
  final ValueChanged<int>? onPlySelected;

  const EvalGraphWidget({
    super.key,
    required this.analyses,
    required this.currentPly,
    this.onSelectPly,
    this.onPlySelected,
  }) : assert(
          onSelectPly != null || onPlySelected != null,
          'Either onSelectPly or onPlySelected must be provided',
        );

  @override
  State<EvalGraphWidget> createState() => _EvalGraphWidgetState();
}

class _EvalGraphWidgetState extends State<EvalGraphWidget> {
  int? _lastNotifiedPly;

  @override
  void didUpdateWidget(covariant EvalGraphWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPly != widget.currentPly) {
      _lastNotifiedPly = widget.currentPly;
    }
  }

  void _notifyPly(int ply) {
    if (widget.analyses.isEmpty) return;
    final minPly = widget.analyses.first.ply;
    final maxPly = widget.analyses.last.ply;
    final clamped = ply.clamp(minPly, maxPly);
    if (_lastNotifiedPly == clamped) return;
    _lastNotifiedPly = clamped;
    (widget.onSelectPly ?? widget.onPlySelected)?.call(clamped);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.analyses.isEmpty) {
      return const SizedBox(
        height: 56,
        child: Center(
          child: Text('Run analysis to view the Win% evaluation curve.'),
        ),
      );
    }

    final analyses = widget.analyses;
    final totalPlies = analyses.length;
    final activePly = widget.currentPly;

    final spots = <FlSpot>[];
    for (var i = 0; i < totalPlies; i++) {
      final a = analyses[i];
      // When ply is odd (White move), winAfter is White's win%.
      // When ply is even (Black move), Black's winAfter means White's win% is 100 - winAfter.
      final whiteWin = a.ply.isOdd ? a.winAfter : (100.0 - a.winAfter);
      spots.add(FlSpot(a.ply.toDouble(), whiteWin.clamp(0.0, 100.0)));
    }

    final minPly = analyses.first.ply;
    final maxPly = analyses.last.ply;
    final double minX;
    final double maxX;
    if (minPly == maxPly) {
      minX = minPly - 0.5;
      maxX = maxPly + 0.5;
    } else {
      minX = minPly.toDouble();
      maxX = maxPly.toDouble();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final lineColor = isDark ? const Color(0xFF64B5F6) : const Color(0xFF1E88E5);
    final midLineColor = isDark ? Colors.white24 : Colors.grey.shade400;
    const markerColor = Color(0xFFD81B60);
    final cardBg = isDark ? const Color(0xFF263238) : const Color(0xFFECEFF1);

    return Semantics(
      label: 'Win probability evaluation graph. Drag horizontally to scrub through moves.',
      child: Container(
        height: 64,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;

            void handlePosition(Offset localPosition) {
              if (width <= 0 || analyses.isEmpty) return;
              final ratio = (localPosition.dx / width).clamp(0.0, 1.0);
              final index = (ratio * (analyses.length - 1)).round().clamp(0, analyses.length - 1);
              final targetPly = analyses[index].ply;
              _notifyPly(targetPly);
            }

            return LineChart(
              LineChartData(
                minX: minX,
                maxX: maxX,
                minY: 0.0,
                maxY: 100.0,
                clipData: const FlClipData.all(),
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineTouchData: LineTouchData(
                  enabled: true,
                  handleBuiltInTouches: true,
                  touchSpotThreshold: double.infinity,
                  touchTooltipData: LineTouchTooltipData(
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    tooltipPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    getTooltipColor: (_) => isDark ? Colors.grey.shade800 : Colors.black87,
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        final ply = spot.x.round();
                        final moveNum = ((ply + 1) ~/ 2);
                        final isWhite = ply.isOdd;
                        final plyStr = isWhite ? '$moveNum.' : '$moveNum...';
                        return LineTooltipItem(
                          '$plyStr ${spot.y.toStringAsFixed(0)}% Win',
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      }).toList();
                    },
                  ),
                  touchCallback: (FlTouchEvent event, LineTouchResponse? response) {
                    if (event is FlTapUpEvent || event is FlPanUpdateEvent) {
                      if (response?.lineBarSpots != null &&
                          response!.lineBarSpots!.isNotEmpty) {
                        final touchedPly = response.lineBarSpots!.first.x.round();
                        _notifyPly(touchedPly);
                      } else if (event.localPosition != null) {
                        handlePosition(event.localPosition!);
                      }
                    } else if (event is FlPanEndEvent || event is FlPanCancelEvent) {
                      _lastNotifiedPly = null;
                    }
                  },
                ),
                  extraLinesData: ExtraLinesData(
                    horizontalLines: [
                      // Midline 50%
                      HorizontalLine(
                        y: 50.0,
                        color: midLineColor,
                        strokeWidth: 1.0,
                        dashArray: [4, 4],
                      ),
                    ],
                    verticalLines: [
                      // Current ply scrubbing marker
                      if (activePly >= minPly && activePly <= maxPly)
                        VerticalLine(
                          x: activePly.toDouble(),
                          color: markerColor,
                          strokeWidth: 2.0,
                        ),
                    ],
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: false,
                      barWidth: 2.0,
                      color: lineColor,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: lineColor.withValues(alpha: 0.15),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    }
}
