import 'package:intl/intl.dart';

/// A medication the user takes on a repeating schedule.
class Medication {
  const Medication({
    this.id,
    required this.name,
    this.dosage = '',
    required this.timesOfDay,
    required this.daysOfWeek,
    this.active = true,
    this.notes = '',
  });

  final int? id;
  final String name;
  final String dosage;

  /// Minutes past midnight, e.g. 8:30 -> 510. Sorted ascending.
  final List<int> timesOfDay;

  /// ISO weekdays: 1 = Monday ... 7 = Sunday.
  final Set<int> daysOfWeek;

  final bool active;
  final String notes;

  static const everyDay = {1, 2, 3, 4, 5, 6, 7};

  bool occursOn(DateTime day) => daysOfWeek.contains(day.weekday);

  /// True if this exact date+time-of-day is still a real dose under this medication's
  /// *current* schedule. Used to tell a legitimately-scheduled dose apart from an
  /// orphan: a dose row created before the medication's times/days were edited, which
  /// would otherwise sit in the database forever, still pending, still getting a real
  /// alarm armed for it -- invisible in the editor because it no longer belongs to any
  /// time the medication actually lists.
  bool coversSlot(DateTime scheduledAt) =>
      active && occursOn(scheduledAt) && timesOfDay.contains(scheduledAt.hour * 60 + scheduledAt.minute);

  /// Formats "minutes past midnight" as e.g. "09:00".
  static String formatTime(int minutes) =>
      DateFormat('HH:mm').format(DateTime(2000, 1, 1, 0, minutes));

  Medication copyWith({
    int? id,
    String? name,
    String? dosage,
    List<int>? timesOfDay,
    Set<int>? daysOfWeek,
    bool? active,
    String? notes,
  }) =>
      Medication(
        id: id ?? this.id,
        name: name ?? this.name,
        dosage: dosage ?? this.dosage,
        timesOfDay: timesOfDay ?? this.timesOfDay,
        daysOfWeek: daysOfWeek ?? this.daysOfWeek,
        active: active ?? this.active,
        notes: notes ?? this.notes,
      );

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'name': name,
        'dosage': dosage,
        'times_of_day': timesOfDay.join(','),
        'days_of_week': daysOfWeek.join(','),
        'active': active ? 1 : 0,
        'notes': notes,
      };

  static Medication fromRow(Map<String, Object?> row) => Medication(
        id: row['id'] as int?,
        name: row['name'] as String,
        dosage: (row['dosage'] as String?) ?? '',
        timesOfDay: _parseInts(row['times_of_day'] as String?).toList()..sort(),
        daysOfWeek: _parseInts(row['days_of_week'] as String?).toSet(),
        active: (row['active'] as int? ?? 1) == 1,
        notes: (row['notes'] as String?) ?? '',
      );

  static Iterable<int> _parseInts(String? raw) =>
      (raw ?? '').split(',').where((s) => s.trim().isNotEmpty).map(int.parse);
}

enum DoseStatus { pending, taken, skipped, missed }

/// One scheduled occurrence of a medication.
class Dose {
  const Dose({
    this.id,
    required this.medicationId,
    required this.scheduledAt,
    this.status = DoseStatus.pending,
    this.actionedAt,
    this.firedAt,
  });

  final int? id;
  final int medicationId;
  final DateTime scheduledAt;
  final DoseStatus status;
  final DateTime? actionedAt;

  /// When the alarm actually rang, per the native receiver -- independent of
  /// [actionedAt], which is when the user responded (if they did). Null means either
  /// the alarm hasn't fired yet, or (for doses from before this field existed) it's
  /// simply unknown. Used to tell "never rang" (a real bug) apart from "rang and was
  /// ignored" (not a bug) for missed doses.
  final DateTime? firedAt;

  /// Grace period before a pending dose counts as missed.
  static const missedAfter = Duration(hours: 2);

  DoseStatus effectiveStatus(DateTime now) =>
      status == DoseStatus.pending && now.isAfter(scheduledAt.add(missedAfter))
          ? DoseStatus.missed
          : status;

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'medication_id': medicationId,
        'scheduled_at': scheduledAt.millisecondsSinceEpoch,
        'status': status.name,
        'actioned_at': actionedAt?.millisecondsSinceEpoch,
        'fired_at': firedAt?.millisecondsSinceEpoch,
      };

  static Dose fromRow(Map<String, Object?> row) => Dose(
        id: row['id'] as int?,
        medicationId: row['medication_id'] as int,
        scheduledAt:
            DateTime.fromMillisecondsSinceEpoch(row['scheduled_at'] as int),
        status: DoseStatus.values.firstWhere(
          (s) => s.name == row['status'],
          orElse: () => DoseStatus.pending,
        ),
        actionedAt: row['actioned_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['actioned_at'] as int),
        firedAt: row['fired_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['fired_at'] as int),
      );
}
