import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// GitHub-style contribution grid: one column per week, one row per weekday,
/// coloured by how many of that day's doses were taken.
class AdherenceGrid extends StatelessWidget {
  const AdherenceGrid({super.key, required this.data, required this.today});

  final Map<DateTime, ({int taken, int total})> data;
  final DateTime today;

  static const _cell = 16.0;
  static const _gap = 4.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final weeks =
            ((constraints.maxWidth + _gap) / (_cell + _gap)).floor().clamp(4, 26);
        final weekStart = mondayOf(today).subtract(Duration(days: 7 * (weeks - 1)));

        return SizedBox(
          height: 7 * _cell + 6 * _gap,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var w = 0; w < weeks; w++)
                Padding(
                  padding: EdgeInsets.only(right: w == weeks - 1 ? 0 : _gap),
                  child: Column(
                    children: [
                      for (var d = 0; d < 7; d++)
                        Padding(
                          padding: EdgeInsets.only(bottom: d == 6 ? 0 : _gap),
                          child: _daySquare(
                            context,
                            weekStart.add(Duration(days: 7 * w + d)),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _daySquare(BuildContext context, DateTime day) {
    final entry = data[DateTime(day.year, day.month, day.day)];
    final isFuture = day.isAfter(today);
    return Tooltip(
      message: isFuture || entry == null
          ? _fmt(day)
          : '${_fmt(day)}: ${entry.taken}/${entry.total} taken',
      child: Container(
        width: _cell,
        height: _cell,
        decoration: BoxDecoration(
          color: isFuture ? Colors.transparent : _colorFor(context, entry),
          borderRadius: BorderRadius.circular(3),
          border: isFuture
              ? Border.all(color: Theme.of(context).dividerColor, width: 1)
              : null,
        ),
      ),
    );
  }

  Color _colorFor(BuildContext context, ({int taken, int total})? entry) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    if (entry == null || entry.total == 0) return base;
    if (entry.taken == 0) return Colors.redAccent.withValues(alpha: 0.5);
    const green = Color(0xFF6EE7A8);
    final ratio = entry.taken / entry.total;
    return Color.lerp(base, green, 0.25 + 0.75 * ratio)!;
  }

  /// The Monday on or before [day], so week columns always start Monday
  /// regardless of which weekday [day] itself falls on.
  static DateTime mondayOf(DateTime day) =>
      DateTime(day.year, day.month, day.day)
          .subtract(Duration(days: day.weekday - 1));

  static String _fmt(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
}
