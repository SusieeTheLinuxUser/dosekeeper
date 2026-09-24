import 'dart:convert';

import 'package:intl/intl.dart';

import '../models/medication.dart';

/// A complete, self-contained copy of everything DoseKeeper stores: every medication
/// and every dose, including history.
///
/// Why this exists: the on-device database used to be the only copy of the user's
/// data. On 2026-09-24 a single uninstall (an agent told the user to run plain
/// `flutter install`) deleted all of it -- medications, dose history, the `fired_at`
/// records that proved the overnight alarm test -- with nothing to restore from.
///
/// The format is plain, human-readable JSON so a backup can be inspected, copied to a
/// computer, or repaired by hand. Timestamps carry their UTC offset, so a backup means
/// the same instants wherever it's restored.
class Backup {
  const Backup({
    required this.exportedAt,
    required this.medications,
    required this.doses,
  });

  final DateTime exportedAt;

  /// Ids here are the backup's own and only meaningful inside it (doses point at
  /// medications by them). A restore assigns fresh ids.
  final List<Medication> medications;
  final List<Dose> doses;

  static const appTag = 'dosekeeper';
  static const formatVersion = 1;

  bool get isEmpty => medications.isEmpty && doses.isEmpty;

  String encode() => const JsonEncoder.withIndent('  ').convert({
        'app': appTag,
        'format': formatVersion,
        'exportedAt': formatTimestamp(exportedAt),
        'medications': [
          for (final m in medications)
            {
              'id': m.id,
              'name': m.name,
              'dosage': m.dosage,
              'times': m.timesOfDay.map(Medication.formatTime).toList(),
              'days': m.daysOfWeek.toList()..sort(),
              'active': m.active,
              'notes': m.notes,
            },
        ],
        'doses': [
          for (final d in doses)
            {
              'medicationId': d.medicationId,
              'scheduledAt': formatTimestamp(d.scheduledAt),
              'status': d.status.name,
              'actionedAt': d.actionedAt == null ? null : formatTimestamp(d.actionedAt!),
              'firedAt': d.firedAt == null ? null : formatTimestamp(d.firedAt!),
            },
        ],
      });

  /// Parses and validates a backup. Throws [FormatException] with a message fit to
  /// show the user if the file isn't a DoseKeeper backup or is damaged -- a restore
  /// replaces everything, so a half-understood file must never get that far.
  static Backup decode(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('This file is not a DoseKeeper backup (not valid JSON).');
    }
    if (json is! Map<String, dynamic> || json['app'] != appTag) {
      throw const FormatException('This file is not a DoseKeeper backup.');
    }
    final format = json['format'];
    if (format is! int || format > formatVersion) {
      throw const FormatException(
        'This backup was made by a newer version of DoseKeeper. Update the app first.',
      );
    }

    try {
      final meds = [
        for (final m in json['medications'] as List<dynamic>)
          _decodeMedication(m as Map<String, dynamic>),
      ];
      final medIds = {for (final m in meds) m.id};
      if (medIds.length != meds.length) {
        throw const FormatException('two medications share an id');
      }

      final doses = [
        for (final d in json['doses'] as List<dynamic>)
          _decodeDose(d as Map<String, dynamic>),
      ];
      for (final d in doses) {
        if (!medIds.contains(d.medicationId)) {
          throw FormatException('a dose refers to missing medication ${d.medicationId}');
        }
      }

      return Backup(
        exportedAt: parseTimestamp(json['exportedAt'] as String),
        medications: meds,
        doses: doses,
      );
    } on FormatException catch (e) {
      throw FormatException('This backup file is damaged: ${e.message}');
    } on TypeError {
      throw const FormatException('This backup file is damaged: unexpected structure.');
    }
  }

  static Medication _decodeMedication(Map<String, dynamic> m) {
    final times = [for (final t in m['times'] as List<dynamic>) _parseTime(t as String)]
      ..sort();
    final days = {for (final d in m['days'] as List<dynamic>) d as int};
    if (times.isEmpty) throw const FormatException('a medication has no times');
    if (days.isEmpty || days.any((d) => d < 1 || d > 7)) {
      throw const FormatException('a medication has invalid days');
    }
    return Medication(
      id: m['id'] as int,
      name: m['name'] as String,
      dosage: m['dosage'] as String? ?? '',
      timesOfDay: times,
      daysOfWeek: days,
      active: m['active'] as bool? ?? true,
      notes: m['notes'] as String? ?? '',
    );
  }

  static Dose _decodeDose(Map<String, dynamic> d) {
    final statusName = d['status'] as String;
    final status = DoseStatus.values.where((s) => s.name == statusName).firstOrNull;
    // "missed" is derived at runtime from a pending dose, never stored.
    if (status == null || status == DoseStatus.missed) {
      throw FormatException('unknown dose status "$statusName"');
    }
    DateTime? optional(String key) =>
        d[key] == null ? null : parseTimestamp(d[key] as String);
    return Dose(
      medicationId: d['medicationId'] as int,
      scheduledAt: parseTimestamp(d['scheduledAt'] as String),
      status: status,
      actionedAt: optional('actionedAt'),
      firedAt: optional('firedAt'),
    );
  }

  static int _parseTime(String hhmm) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm);
    final h = match == null ? null : int.parse(match.group(1)!);
    final m = match == null ? null : int.parse(match.group(2)!);
    if (h == null || m == null || h > 23 || m > 59) {
      throw FormatException('invalid time "$hhmm"');
    }
    return h * 60 + m;
  }

  /// Local wall-clock time plus its UTC offset, e.g. `2026-09-21T07:00:00+02:00`.
  static String formatTimestamp(DateTime t) {
    final local = t.toLocal();
    final offset = local.timeZoneOffset;
    final minutes = offset.inMinutes.abs();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(local)}'
        '${offset.isNegative ? '-' : '+'}${two(minutes ~/ 60)}:${two(minutes % 60)}';
  }

  static DateTime parseTimestamp(String s) {
    final parsed = DateTime.tryParse(s);
    if (parsed == null) throw FormatException('invalid timestamp "$s"');
    return parsed.toLocal();
  }

  // --- backup files ---

  static final _fileName = RegExp(r'^dosekeeper-backup-(\d{4}-\d{2}-\d{2})\.json$');

  /// One file per day, rewritten every time a backup runs that day -- so today's file
  /// is always current, and earlier days' files are untouched snapshots to fall back
  /// on if something went wrong today.
  static String fileNameFor(DateTime day) =>
      'dosekeeper-backup-${DateFormat('yyyy-MM-dd').format(day)}.json';

  static bool isBackupFileName(String name) => _fileName.hasMatch(name);

  /// Backup files in [names], newest first. Anything else in the folder is ignored.
  static List<String> newestFirst(Iterable<String> names) =>
      names.where(isBackupFileName).toList()..sort((a, b) => b.compareTo(a));

  /// The day a backup file is for, e.g. 2026-09-24, for showing to the user.
  static String? dayOf(String name) => _fileName.firstMatch(name)?.group(1);

  /// Which backup files to delete so only the newest [keep] remain. Only ever names
  /// DoseKeeper's own files -- never anything else the user keeps in that folder.
  static List<String> toPrune(Iterable<String> names, {required int keep}) =>
      newestFirst(names).skip(keep).toList();
}
