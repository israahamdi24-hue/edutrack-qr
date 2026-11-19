import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../services/admin_data_service.dart';

class AdminAttendanceCharts extends StatelessWidget {
  const AdminAttendanceCharts({
    super.key,
    required this.records,
    required this.periodStart,
    required this.periodEnd,
  });

  final List<AdminAttendance> records;
  final DateTime? periodStart;
  final DateTime? periodEnd;

  @override
  Widget build(BuildContext context) {
    final statusCounts = <String, int>{'present': 0, 'late': 0, 'absent': 0};
    for (final record in records) {
      if (statusCounts.containsKey(record.status)) {
        statusCounts.update(record.status, (count) => count + 1);
      }
    }
    final buckets = _buildBuckets();
    return LayoutBuilder(
      builder: (context, constraints) {
        final distribution = _StatusDistribution(
          counts: statusCounts,
          total: records.length,
        );
        final trend = _AttendanceTrend(buckets: buckets);
        if (constraints.maxWidth < 720) {
          return Column(
            children: [distribution, const SizedBox(height: 12), trend],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: distribution),
            const SizedBox(width: 12),
            Expanded(child: trend),
          ],
        );
      },
    );
  }

  List<_AttendanceBucket> _buildBuckets() {
    final today = _dateOnly(DateTime.now());
    final start = periodStart == null
        ? today.subtract(const Duration(days: 6))
        : _dateOnly(periodStart!);
    final end = periodEnd == null ? today : _dateOnly(periodEnd!);
    final totalDays = math.max(1, end.difference(start).inDays + 1);
    final maxBucketCount = math.min(14, totalDays);
    final daysPerBucket = (totalDays / maxBucketCount).ceil();
    final bucketCount = (totalDays / daysPerBucket).ceil();
    final buckets = List.generate(bucketCount, (index) {
      final bucketStart = start.add(Duration(days: index * daysPerBucket));
      return _AttendanceBucket(date: bucketStart);
    });

    for (final record in records) {
      final recordDate = _dateOnly(record.recordedAt);
      if (recordDate.isBefore(start) || recordDate.isAfter(end)) continue;
      final dayIndex = recordDate.difference(start).inDays;
      final bucketIndex = math.min(bucketCount - 1, dayIndex ~/ daysPerBucket);
      buckets[bucketIndex].add(record.status);
    }
    return buckets;
  }

  DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);
}

class _StatusDistribution extends StatelessWidget {
  const _StatusDistribution({required this.counts, required this.total});

  final Map<String, int> counts;
  final int total;

  static const _items = [
    ('present', 'Présents', AppColors.success),
    ('late', 'Retards', Color(0xFFF0A126)),
    ('absent', 'Absences', AppColors.error),
  ];

  @override
  Widget build(BuildContext context) => _ChartPanel(
    title: 'Répartition des pointages',
    subtitle: 'Données correspondant aux filtres sélectionnés',
    child: Column(
      children: [
        SizedBox(
          height: 184,
          child: CustomPaint(
            painter: _DonutPainter(
              values: [for (final item in _items) counts[item.$1] ?? 0],
              colors: [for (final item in _items) item.$3],
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$total',
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Text(
                    'pointages',
                    style: TextStyle(color: AppColors.secondary, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final item in _items)
              _ChartLegend(
                color: item.$3,
                label: '${item.$2} (${counts[item.$1] ?? 0})',
              ),
          ],
        ),
      ],
    ),
  );
}

class _AttendanceTrend extends StatelessWidget {
  const _AttendanceTrend({required this.buckets});

  final List<_AttendanceBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final grouped = buckets.length > 7;
    return _ChartPanel(
      title: 'Évolution des présences',
      subtitle: grouped
          ? 'Par période • ${buckets.length} intervalles'
          : 'Par jour • 7 derniers jours ou période filtrée',
      child: Column(
        children: [
          SizedBox(
            height: 184,
            width: double.infinity,
            child: CustomPaint(painter: _TrendPainter(buckets: buckets)),
          ),
          const Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              _ChartLegend(color: AppColors.success, label: 'Présent'),
              _ChartLegend(color: Color(0xFFF0A126), label: 'Retard'),
              _ChartLegend(color: AppColors.error, label: 'Absent'),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChartPanel extends StatelessWidget {
  const _ChartPanel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: AppColors.border),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: const TextStyle(color: AppColors.secondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _ChartLegend extends StatelessWidget {
  const _ChartLegend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: AppColors.secondary),
      ),
    ],
  );
}

class _AttendanceBucket {
  _AttendanceBucket({required this.date});

  final DateTime date;
  int present = 0;
  int late = 0;
  int absent = 0;

  int get total => present + late + absent;

  void add(String status) {
    switch (status) {
      case 'present':
        present++;
      case 'late':
        late++;
      case 'absent':
        absent++;
    }
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({required this.values, required this.colors});

  final List<int> values;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (sum, value) => sum + value);
    final center = Offset(size.width / 2, size.height / 2);
    const strokeWidth = 22.0;
    final radius = math.min(size.width, size.height) * .34;
    final rect = Rect.fromCircle(center: center, radius: radius);
    if (total == 0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = AppColors.border
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
      return;
    }
    var startAngle = -math.pi / 2;
    for (var index = 0; index < values.length; index++) {
      final sweep = values[index] / total * math.pi * 2;
      if (sweep == 0) continue;
      canvas.drawArc(
        rect,
        startAngle,
        sweep,
        false,
        Paint()
          ..color = colors[index]
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.butt,
      );
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.colors != colors;
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({required this.buckets});

  final List<_AttendanceBucket> buckets;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 28.0;
    const right = 8.0;
    const top = 8.0;
    const bottom = 27.0;
    final chartWidth = math.max(0.0, size.width - left - right);
    final chartHeight = math.max(0.0, size.height - top - bottom);
    final maxValue = buckets.fold<int>(
      0,
      (maximum, bucket) => math.max(maximum, bucket.total),
    );
    final scale = maxValue == 0 ? 1 : maxValue;
    final gridPaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    final labelStyle = const TextStyle(color: AppColors.secondary, fontSize: 9);
    for (var line = 0; line <= 3; line++) {
      final y = top + chartHeight * line / 3;
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width - right, y),
        gridPaint,
      );
      final value = (scale * (3 - line) / 3).round();
      _drawText(canvas, '$value', Offset(0, y - 6), labelStyle);
    }
    if (buckets.isEmpty || chartWidth == 0 || chartHeight == 0) return;
    final slotWidth = chartWidth / buckets.length;
    final barWidth = math.min(24.0, slotWidth * .58);
    for (var index = 0; index < buckets.length; index++) {
      final bucket = buckets[index];
      final x = left + slotWidth * index + (slotWidth - barWidth) / 2;
      var y = top + chartHeight;
      final segments = [
        (bucket.present, AppColors.success),
        (bucket.late, const Color(0xFFF0A126)),
        (bucket.absent, AppColors.error),
      ];
      for (final segment in segments) {
        if (segment.$1 == 0) continue;
        final segmentHeight = chartHeight * segment.$1 / scale;
        y -= segmentHeight;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, barWidth, segmentHeight),
            const Radius.circular(3),
          ),
          Paint()..color = segment.$2,
        );
      }
      if (buckets.length <= 7 || index.isEven) {
        final label = '${bucket.date.day}/${bucket.date.month}';
        _drawText(
          canvas,
          label,
          Offset(x + barWidth / 2 - 12, size.height - bottom + 7),
          labelStyle,
        );
      }
    }
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.buckets != buckets;
}
