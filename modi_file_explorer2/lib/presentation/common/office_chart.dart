import 'dart:math' as math;

import 'package:flutter/material.dart';

class OfficeChartSeries {
  const OfficeChartSeries({
    required this.name,
    required this.values,
    this.color,
  });

  final String name;
  final List<double> values;
  final Color? color;

  factory OfficeChartSeries.fromMap(Map<Object?, Object?> data) {
    return OfficeChartSeries(
      name: data['name'] as String? ?? '',
      values: (data['values'] as List? ?? const [])
          .whereType<num>()
          .map((value) => value.toDouble())
          .toList(growable: false),
      color: data['color'] is int ? Color(data['color']! as int) : null,
    );
  }
}

class OfficeChartData {
  const OfficeChartData({
    required this.type,
    required this.title,
    required this.categories,
    required this.series,
    required this.legend,
    required this.dataLabels,
    required this.isSupported,
  });

  final String type;
  final String title;
  final List<String> categories;
  final List<OfficeChartSeries> series;
  final bool legend;
  final bool dataLabels;
  final bool isSupported;

  bool get supported =>
      isSupported &&
      const {
        'column',
        'bar',
        'line',
        'pie',
        'doughnut',
        'area',
        'scatter',
      }.contains(type.split('-').first);

  factory OfficeChartData.fromMap(Map<Object?, Object?> data) {
    return OfficeChartData(
      type: data['type'] as String? ?? 'unsupported',
      title: data['title'] as String? ?? '',
      categories: (data['categories'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      series: (data['series'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (series) =>
                OfficeChartSeries.fromMap(Map<Object?, Object?>.from(series)),
          )
          .toList(growable: false),
      legend: data['legend'] as bool? ?? false,
      dataLabels: data['dataLabels'] as bool? ?? false,
      isSupported: data['supported'] as bool? ?? true,
    );
  }
}

class OfficeChartView extends StatelessWidget {
  const OfficeChartView({required this.chart, super.key});

  final OfficeChartData chart;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _OfficeChartPainter(chart, Theme.of(context).colorScheme),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _OfficeChartPainter extends CustomPainter {
  _OfficeChartPainter(this.chart, this.scheme);

  static const _colors = <Color>[
    Color(0xff4472c4),
    Color(0xffed7d31),
    Color(0xffa5a5a5),
    Color(0xffffc000),
    Color(0xff5b9bd5),
    Color(0xff70ad47),
  ];

  final OfficeChartData chart;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    if (!chart.supported || chart.series.isEmpty || size.isEmpty) {
      _drawUnavailable(canvas, size);
      return;
    }

    final titleHeight = chart.title.isEmpty ? 0.0 : 28.0;
    final legendHeight = chart.legend ? 28.0 : 0.0;
    final plot = Rect.fromLTWH(
      chart.type == 'bar' ? 42 : 38,
      titleHeight + 8,
      math.max(1, size.width - (chart.type == 'bar' ? 54 : 48)),
      math.max(1, size.height - titleHeight - legendHeight - 36),
    );
    if (chart.title.isNotEmpty) {
      _text(
        canvas,
        chart.title,
        Offset(size.width / 2, 3),
        15,
        color: scheme.onSurface,
        center: true,
        bold: true,
      );
    }

    if (chart.type == 'pie' || chart.type == 'doughnut') {
      _drawPie(canvas, plot);
    } else {
      _drawAxes(canvas, plot);
      if (chart.type == 'line' ||
          chart.type == 'scatter' ||
          chart.type == 'area') {
        _drawLines(canvas, plot);
      } else {
        _drawBars(canvas, plot);
      }
    }
    if (chart.legend) _drawLegend(canvas, size, titleHeight);
  }

  void _drawUnavailable(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = scheme.outlineVariant
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Offset.zero & size, paint);
    _text(
      canvas,
      chart.title.isEmpty
          ? 'Chart not shown'
          : '${chart.title}\nChart not shown',
      Offset(size.width / 2, size.height / 2 - 12),
      13,
      color: scheme.onSurfaceVariant,
      center: true,
    );
  }

  void _drawAxes(Canvas canvas, Rect plot) {
    final line = Paint()
      ..color = scheme.outlineVariant
      ..strokeWidth = 0.7;
    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), line);
      final maxValue = chart.series
          .expand((series) => series.values)
          .fold<double>(
            0,
            (maximum, value) => math.max(maximum, value.abs()).toDouble(),
          );
      _text(
        canvas,
        _number(maxValue * (4 - i) / 4),
        Offset(2, y - 5),
        8,
        color: scheme.onSurfaceVariant,
      );
    }
    canvas.drawLine(
      Offset(plot.left, plot.top),
      Offset(plot.left, plot.bottom),
      Paint()
        ..color = scheme.outline
        ..strokeWidth = 1,
    );
    final count = math.min(chart.categories.length, 12);
    for (var i = 0; i < count; i++) {
      final x = plot.left + plot.width * (i + 0.5) / count;
      _text(
        canvas,
        chart.categories[i],
        Offset(x, plot.bottom + 5),
        9,
        color: scheme.onSurfaceVariant,
        center: true,
      );
    }
  }

  void _drawBars(Canvas canvas, Rect plot) {
    final flattened = chart.series.expand((item) => item.values).toList();
    final maxValue = flattened.fold<double>(
      0,
      (maximum, value) => math.max(maximum, value.abs()),
    );
    if (maxValue == 0) return;
    final count = math.max(1, chart.categories.length);
    final seriesCount = chart.series.length;
    final stacked =
        chart.type.endsWith('-stacked') ||
        chart.type.endsWith('-percentStacked');
    final percentStacked = chart.type.endsWith('-percentStacked');
    if (chart.type.startsWith('bar')) {
      _drawHorizontalBars(
        canvas,
        plot,
        count,
        maxValue,
        stacked,
        percentStacked,
      );
      return;
    }
    final barWidth = plot.width / count * (stacked ? 0.58 : 0.72) / seriesCount;
    final positiveStack = List<double>.filled(count, 0);
    final negativeStack = List<double>.filled(count, 0);
    for (var s = 0; s < seriesCount; s++) {
      final series = chart.series[s];
      final paint = Paint()..color = _color(s, series);
      for (var i = 0; i < series.values.length && i < count; i++) {
        final value = series.values[i];
        final categoryTotal = chart.series.fold<double>(
          0,
          (sum, item) =>
              sum + (i < item.values.length ? item.values[i].abs() : 0),
        );
        final magnitude =
            (percentStacked
                ? (categoryTotal == 0 ? 0 : value.abs() / categoryTotal)
                : value.abs() / maxValue) *
            plot.height;
        final x = plot.left + plot.width * (i + 0.5) / count;
        final bottom = stacked
            ? plot.bottom -
                  (value >= 0 ? positiveStack[i] : negativeStack[i]) /
                      (percentStacked ? categoryTotal : maxValue) *
                      plot.height
            : plot.bottom;
        final rect = Rect.fromLTWH(
          x -
              (stacked
                  ? barWidth * seriesCount / 2
                  : barWidth * seriesCount / 2) +
              s * barWidth,
          bottom - magnitude,
          barWidth,
          magnitude,
        );
        canvas.drawRect(rect, paint);
        if (stacked) {
          if (value >= 0) {
            positiveStack[i] += value.abs();
          } else {
            negativeStack[i] += value.abs();
          }
        }
        if (chart.dataLabels) {
          _text(
            canvas,
            _number(value),
            Offset(x, rect.top - 13),
            9,
            color: scheme.onSurface,
            center: true,
          );
        }
      }
    }
  }

  void _drawHorizontalBars(
    Canvas canvas,
    Rect plot,
    int categoryCount,
    double maxValue,
    bool stacked,
    bool percentStacked,
  ) {
    final groupHeight = plot.height / categoryCount;
    final seriesCount = chart.series.length;
    final barHeight = groupHeight * 0.72 / (stacked ? 1 : seriesCount);
    for (var category = 0; category < categoryCount; category++) {
      final total = chart.series.fold<double>(
        0,
        (sum, series) =>
            sum +
            (category < series.values.length
                ? series.values[category].abs()
                : 0),
      );
      var stackOffset = 0.0;
      for (var seriesIndex = 0; seriesIndex < seriesCount; seriesIndex++) {
        final series = chart.series[seriesIndex];
        if (category >= series.values.length) continue;
        final value = series.values[category];
        final fraction = percentStacked
            ? (total == 0 ? 0 : value.abs() / total)
            : value.abs() / maxValue;
        final width = fraction * plot.width;
        final top =
            plot.top +
            groupHeight * category +
            (stacked
                ? groupHeight * 0.14
                : groupHeight * 0.14 + seriesIndex * barHeight);
        final left = plot.left + (stacked ? stackOffset : 0);
        final rect = Rect.fromLTWH(left, top, width, barHeight);
        canvas.drawRect(rect, Paint()..color = _color(seriesIndex, series));
        if (chart.dataLabels) {
          _text(
            canvas,
            _number(value),
            Offset(rect.right + 3, top),
            9,
            color: scheme.onSurface,
          );
        }
        if (stacked) stackOffset += width;
      }
    }
  }

  void _drawLines(Canvas canvas, Rect plot) {
    final values = chart.series.expand((item) => item.values).toList();
    final maxValue = values.fold<double>(
      0,
      (maximum, value) => math.max(maximum, value.abs()),
    );
    final count = math.max(2, chart.categories.length);
    if (maxValue == 0) return;
    for (var s = 0; s < chart.series.length; s++) {
      final item = chart.series[s];
      final path = Path();
      for (var i = 0; i < item.values.length; i++) {
        final x = plot.left + plot.width * i / (count - 1);
        final y = plot.bottom - item.values[i] / maxValue * plot.height;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        canvas.drawCircle(Offset(x, y), 2.5, Paint()..color = _color(s, item));
        if (chart.dataLabels) {
          _text(
            canvas,
            _number(item.values[i]),
            Offset(x, y - 14),
            9,
            color: scheme.onSurface,
            center: true,
          );
        }
      }
      if (chart.type == 'area' && item.values.isNotEmpty) {
        path
          ..lineTo(
            plot.left + plot.width * (item.values.length - 1) / (count - 1),
            plot.bottom,
          )
          ..lineTo(plot.left, plot.bottom)
          ..close();
        canvas.drawPath(
          path,
          Paint()..color = _color(s, item).withValues(alpha: 0.22),
        );
      }
      if (chart.type != 'scatter') {
        canvas.drawPath(
          path,
          Paint()
            ..color = _color(s, item)
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
    }
  }

  void _drawPie(Canvas canvas, Rect plot) {
    final values = chart.series.first.values;
    final total = values.fold<double>(0, (sum, value) => sum + value.abs());
    if (total == 0) return;
    final diameter = math.min(plot.width, plot.height) * 0.9;
    final rect = Rect.fromCenter(
      center: plot.center,
      width: diameter,
      height: diameter,
    );
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i].abs() / total * math.pi * 2;
      final paint = Paint()..color = _color(i, chart.series.first);
      canvas.drawArc(rect, start, sweep, true, paint);
      if (chart.dataLabels) {
        final mid = start + sweep / 2;
        final center = Offset(
          plot.center.dx + math.cos(mid) * diameter * 0.32,
          plot.center.dy + math.sin(mid) * diameter * 0.32,
        );
        _text(
          canvas,
          _number(values[i]),
          center,
          10,
          color: Colors.white,
          center: true,
        );
      }
      start += sweep;
    }
    if (chart.type == 'doughnut') {
      canvas.drawCircle(
        plot.center,
        diameter * 0.23,
        Paint()..color = scheme.surface,
      );
    }
  }

  void _drawLegend(Canvas canvas, Size size, double top) {
    var x = 8.0;
    final y = size.height - 18;
    final isPie = chart.type == 'pie' || chart.type == 'doughnut';
    final count = isPie ? chart.categories.length : chart.series.length;
    for (var i = 0; i < count; i++) {
      final item = isPie
          ? OfficeChartSeries(name: chart.categories[i], values: const [])
          : chart.series[i];
      canvas.drawRect(
        Rect.fromLTWH(x, y + 3, 9, 9),
        Paint()..color = isPie ? _colors[i % _colors.length] : _color(i, item),
      );
      x += 13;
      final width = _text(
        canvas,
        item.name,
        Offset(x, y),
        9,
        color: scheme.onSurfaceVariant,
      );
      x += width + 14;
      if (x > size.width - 30) break;
    }
  }

  Color _color(int index, OfficeChartSeries series) =>
      series.color ?? _colors[index % _colors.length];

  String _number(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsPrecision(3);

  double _text(
    Canvas canvas,
    String value,
    Offset offset,
    double fontSize, {
    required Color color,
    bool center = false,
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 140);
    canvas.save();
    canvas.translate(
      center ? offset.dx - painter.width / 2 : offset.dx,
      offset.dy,
    );
    painter.paint(canvas, Offset.zero);
    canvas.restore();
    return painter.width;
  }

  @override
  bool shouldRepaint(covariant _OfficeChartPainter oldDelegate) =>
      oldDelegate.chart != chart || oldDelegate.scheme != scheme;
}
