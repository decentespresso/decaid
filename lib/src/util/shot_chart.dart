import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';

class ShotChart extends StatefulWidget {
  final List<ShotSnapshot> shotSnapshots;
  final DateTime shotStartTime;
  final bool isLiveShot;

  const ShotChart({
    super.key,
    required this.shotSnapshots,
    required this.shotStartTime,
    this.isLiveShot = false,
  });

  @override
  State<ShotChart> createState() => _ShotChartState();
}

class _LineInfo {
  final String label;
  final String unit;
  final bool isTemp;

  const _LineInfo(this.label, this.unit, {this.isTemp = false});
}

class _ShotChartState extends State<ShotChart> {
  static const double _leftMaxY = 11.0;
  static const double _tempMaxY = 160.0;
  static const double _tempScale = _leftMaxY / _tempMaxY;

  static const List<_LineInfo> _lineInfo = [
    _LineInfo('Flow', 'ml/s'),
    _LineInfo('Pressure', 'bar'),
    _LineInfo('Target flow', 'ml/s'),
    _LineInfo('Target pressure', 'bar'),
    _LineInfo('Group temp', '°C', isTemp: true),
    _LineInfo('Mix temp', '°C', isTemp: true),
    _LineInfo('Target group temp', '°C', isTemp: true),
    _LineInfo('Target mix temp', '°C', isTemp: true),
    _LineInfo('Steam temp', '°C', isTemp: true),
  ];

  @override
  void dispose() {
    PaintingBinding.instance.imageCache.clearLiveImages();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _shotChart(context);
  }

  Widget _shotChart(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 500),
        child: RepaintBoundary(
          child: LineChart(
            LineChartData(
              lineBarsData: _shotChartData(),
              minY: 0,
              maxY: _leftMaxY,
              titlesData: _titles(context),
              lineTouchData: _touchData(context),
            ),
            duration: widget.isLiveShot
                ? Duration(milliseconds: 300)
                : Duration.zero,
          ),
        ),
      ),
    );
  }

  List<_LineInfo> get _allLineInfo {
    final info = List<_LineInfo>.from(_lineInfo);
    if (widget.shotSnapshots.firstOrNull?.scale != null) {
      info.add(const _LineInfo('Weight', 'g'));
      info.add(const _LineInfo('Weight flow', 'g/s'));
    }
    return info;
  }

  LineTouchData _touchData(BuildContext context) {
    return LineTouchData(
      touchTooltipData: LineTouchTooltipData(
        tooltipBorderRadius: BorderRadius.circular(8),
        maxContentWidth: 200,
        fitInsideHorizontally: true,
        fitInsideVertically: true,
        getTooltipItems: (touchedSpots) {
          final allInfo = _allLineInfo;
          return touchedSpots.map((spot) {
            final idx = spot.barIndex;
            final color = spot.bar.color ?? Colors.blue;

            if (idx < allInfo.length) {
              final info = allInfo[idx];
              final value = info.isTemp
                  ? (spot.y / _tempScale).toStringAsFixed(1)
                  : spot.y.toStringAsFixed(1);
              return LineTooltipItem(
                '${info.label}: $value ${info.unit}',
                TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              );
            }
            return LineTooltipItem(
              spot.y.toStringAsFixed(1),
              TextStyle(color: color, fontSize: 12),
            );
          }).toList();
        },
      ),
    );
  }

  FlTitlesData _titles(BuildContext context) {
    return FlTitlesData(
      topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 32,
          interval: 2,
          getTitlesWidget: (value, meta) {
            if (value == meta.max || value == meta.min) {
              return const SizedBox.shrink();
            }
            return SideTitleWidget(
              meta: meta,
              child: Text(
                value.toInt().toString(),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            );
          },
        ),
      ),
      rightTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 40,
          interval: 2,
          getTitlesWidget: (value, meta) {
            if (value == meta.max || value == meta.min) {
              return const SizedBox.shrink();
            }
            final tempValue = (value / _tempScale).round();
            return SideTitleWidget(
              meta: meta,
              child: Text(
                '$tempValue°',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: Colors.red.shade300),
              ),
            );
          },
        ),
      ),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          getTitlesWidget: (value, meta) =>
              _buildBottomTitle(value, meta, context),
        ),
      ),
    );
  }

  Widget _buildBottomTitle(double value, TitleMeta meta, BuildContext context) {
    final int seconds = (value / 1000).toInt();
    String text;

    if (value / 1000 < 60) {
      if (value.toInt() % 1000 == 0) {
        text = '$seconds s';
      } else {
        return Container();
      }
    } else if (value / 1000 <= 120) {
      final int minutes = seconds ~/ 60;
      final int remainingSeconds = seconds % 60;
      if (seconds % 15 == 0) {
        text = '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
      } else {
        return Container();
      }
    } else {
      final int minutes = seconds ~/ 60;
      if (seconds % 60 == 0) {
        text = '$minutes:00';
      } else {
        return Container();
      }
    }
    return SideTitleWidget(
      meta: meta,
      space: 8.0,
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    );
  }

  List<LineChartBarData> _shotChartData() {
    return [
      LineChartBarData(
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots
            .map((e) => FlSpot(_timestamp(e.machine.timestamp), e.machine.flow))
            .toList(),
      ),
      LineChartBarData(
        color: Colors.green,
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots
            .map(
              (e) =>
                  FlSpot(_timestamp(e.machine.timestamp), e.machine.pressure),
            )
            .toList(),
      ),
      LineChartBarData(
        dotData: FlDotData(show: false),
        dashArray: [5, 5],
        spots: widget.shotSnapshots
            .map(
              (e) =>
                  FlSpot(_timestamp(e.machine.timestamp), e.machine.targetFlow),
            )
            .toList(),
      ),
      LineChartBarData(
        color: Colors.green,
        dashArray: [5, 5],
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots
            .map(
              (e) => FlSpot(
                _timestamp(e.machine.timestamp),
                e.machine.targetPressure,
              ),
            )
            .toList(),
      ),
      LineChartBarData(
        color: Colors.red,
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots
            .map(
              (e) => FlSpot(
                _timestamp(e.machine.timestamp),
                e.machine.groupTemperature * _tempScale,
              ),
            )
            .toList(),
      ),
      LineChartBarData(
        color: Colors.orange,
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots
            .map(
              (e) => FlSpot(
                _timestamp(e.machine.timestamp),
                e.machine.mixTemperature * _tempScale,
              ),
            )
            .toList(),
      ),
      LineChartBarData(
        color: Colors.red,
        dashArray: [5, 5],
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots
            .map(
              (e) => FlSpot(
                _timestamp(e.machine.timestamp),
                e.machine.targetGroupTemperature * _tempScale,
              ),
            )
            .toList(),
      ),
      LineChartBarData(
        color: Colors.orange,
        dashArray: [5, 5],
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots
            .map(
              (e) => FlSpot(
                _timestamp(e.machine.timestamp),
                e.machine.targetMixTemperature * _tempScale,
              ),
            )
            .toList(),
      ),
      LineChartBarData(
        color: Colors.deepOrange,
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots
            .map(
              (e) => FlSpot(
                _timestamp(e.machine.timestamp),
                e.machine.steamTemperature * _tempScale,
              ),
            )
            .toList(),
      ),
      ..._scaleData(),
    ];
  }

  List<LineChartBarData> _scaleData() {
    if (widget.shotSnapshots.firstOrNull?.scale == null) {
      return [];
    }
    return [
      LineChartBarData(
        color: Colors.purpleAccent,
        dashArray: [5, 5],
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots
            .map(
              (e) => FlSpot(
                _timestamp(e.machine.timestamp),
                e.scale!.weight / 10.0,
              ),
            )
            .toList(),
      ),
      LineChartBarData(
        color: Colors.purple,
        dotData: FlDotData(show: false),
        spots: widget.shotSnapshots.map((e) {
          return FlSpot(_timestamp(e.machine.timestamp), e.scale!.weightFlow);
        }).toList(),
      ),
    ];
  }

  double _timestamp(DateTime snapshot) {
    return snapshot.difference(widget.shotStartTime).inMilliseconds.toDouble();
  }
}
