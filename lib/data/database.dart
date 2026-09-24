import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/medication.dart';

/// Local SQLite store. Everything lives on-device; there is no server and no account.
class DoseDatabase {
  DoseDatabase._();
  static final DoseDatabase instance = DoseDatabase._();

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'dosekeeper.db');
    return openDatabase(
      path,
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE medications (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            dosage TEXT NOT NULL DEFAULT '',
            times_of_day TEXT NOT NULL,
            days_of_week TEXT NOT NULL,
            active INTEGER NOT NULL DEFAULT 1,
            notes TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE doses (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            medication_id INTEGER NOT NULL,
            scheduled_at INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            actioned_at INTEGER,
            fired_at INTEGER,
            UNIQUE (medication_id, scheduled_at),
            FOREIGN KEY (medication_id) REFERENCES medications (id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_doses_scheduled ON doses (scheduled_at)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 -> v2: fired_at records when an alarm actually rang, independent of what
        // the user did about it. Lets a missed dose be attributed to "never fired"
        // (a real bug) vs. "fired and was ignored" (not a bug), instead of a mystery.
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE doses ADD COLUMN fired_at INTEGER');
        }
      },
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
  }

  // --- medications ---

  Future<List<Medication>> medications({bool activeOnly = false}) async {
    final db = await database;
    final rows = await db.query(
      'medications',
      where: activeOnly ? 'active = 1' : null,
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(Medication.fromRow).toList();
  }

  Future<Medication?> medication(int id) async {
    final db = await database;
    final rows = await db.query('medications', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Medication.fromRow(rows.first);
  }

  Future<int> upsertMedication(Medication med) async {
    final db = await database;
    if (med.id == null) return db.insert('medications', med.toRow());
    await db.update('medications', med.toRow(),
        where: 'id = ?', whereArgs: [med.id]);
    return med.id!;
  }

  Future<void> deleteMedication(int id) async {
    final db = await database;
    await db.delete('medications', where: 'id = ?', whereArgs: [id]);
  }

  // --- doses ---

  /// Inserts a dose unless one already exists for that medication+time.
  Future<int?> ensureDose(int medicationId, DateTime scheduledAt) async {
    final db = await database;
    return db.insert(
      'doses',
      Dose(medicationId: medicationId, scheduledAt: scheduledAt).toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Dose>> dosesBetween(DateTime from, DateTime to) async {
    final db = await database;
    final rows = await db.query(
      'doses',
      where: 'scheduled_at >= ? AND scheduled_at < ?',
      whereArgs: [from.millisecondsSinceEpoch, to.millisecondsSinceEpoch],
      orderBy: 'scheduled_at',
    );
    return rows.map(Dose.fromRow).toList();
  }

  Future<Dose?> dose(int id) async {
    final db = await database;
    final rows = await db.query('doses', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Dose.fromRow(rows.first);
  }

  /// Removes a dose row outright, rather than marking it skipped -- for a dose that
  /// should never have existed in the first place (its medication's schedule no longer
  /// includes that time/day), not one a real decision was made about.
  Future<void> deleteDose(int id) async {
    final db = await database;
    await db.delete('doses', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setDoseStatus(int doseId, DoseStatus status,
      {DateTime? at}) async {
    final db = await database;
    await db.update(
      'doses',
      {
        'status': status.name,
        'actioned_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [doseId],
    );
  }

  /// Records when a dose's alarm actually fired. Only sets it the first time -- a
  /// snoozed dose re-fires under the same dose ID, and the first ring is the one that
  /// matters for "did it fire on time".
  Future<void> setDoseFiredAt(int doseId, DateTime firedAt) async {
    final db = await database;
    await db.update(
      'doses',
      {'fired_at': firedAt.millisecondsSinceEpoch},
      where: 'id = ? AND fired_at IS NULL',
      whereArgs: [doseId],
    );
  }

  /// Every dose ever recorded, oldest first -- for backups.
  Future<List<Dose>> allDoses() async {
    final db = await database;
    final rows = await db.query('doses', orderBy: 'scheduled_at');
    return rows.map(Dose.fromRow).toList();
  }

  /// Replaces all medications and doses with [meds] and [doses], atomically: either the
  /// restore lands completely or the old data is left exactly as it was.
  ///
  /// Everything gets a fresh id (doses are re-pointed at their medication's new id).
  /// AUTOINCREMENT never reuses an id, so nothing restored can collide with a native
  /// alarm or an undrained alarm-screen outcome still keyed by an old dose id.
  Future<void> replaceAll(List<Medication> meds, List<Dose> doses) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('doses');
      await txn.delete('medications');
      final newIds = <int?, int>{};
      for (final m in meds) {
        newIds[m.id] = await txn.insert(
          'medications',
          Medication(
            name: m.name,
            dosage: m.dosage,
            timesOfDay: m.timesOfDay,
            daysOfWeek: m.daysOfWeek,
            active: m.active,
            notes: m.notes,
          ).toRow(),
        );
      }
      for (final d in doses) {
        final medId = newIds[d.medicationId];
        if (medId == null) continue;
        await txn.insert(
          'doses',
          Dose(
            medicationId: medId,
            scheduledAt: d.scheduledAt,
            status: d.status,
            actionedAt: d.actionedAt,
            firedAt: d.firedAt,
          ).toRow(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  /// Still-pending doses whose scheduled time has already passed. The caller decides
  /// how much grace to allow before treating one as missed.
  Future<List<Dose>> pendingDosesBefore(DateTime cutoff) async {
    final db = await database;
    final rows = await db.query(
      'doses',
      where: 'scheduled_at < ? AND status = ?',
      whereArgs: [cutoff.millisecondsSinceEpoch, DoseStatus.pending.name],
      orderBy: 'scheduled_at',
    );
    return rows.map(Dose.fromRow).toList();
  }

  /// Doses still in the future, used to arm native alarms.
  Future<List<Dose>> upcomingPendingDoses(DateTime now, DateTime until) async {
    final db = await database;
    final rows = await db.query(
      'doses',
      where: 'scheduled_at >= ? AND scheduled_at < ? AND status = ?',
      whereArgs: [
        now.millisecondsSinceEpoch,
        until.millisecondsSinceEpoch,
        DoseStatus.pending.name,
      ],
      orderBy: 'scheduled_at',
    );
    return rows.map(Dose.fromRow).toList();
  }

  /// Per-day taken/total counts, for the activity grid.
  Future<Map<DateTime, ({int taken, int total})>> dailyAdherence(
    DateTime from,
    DateTime to,
  ) async {
    final doses = await dosesBetween(from, to);
    final now = DateTime.now();
    final out = <DateTime, ({int taken, int total})>{};
    for (final d in doses) {
      // A dose that hasn't reached its scheduled time yet isn't missed or taken --
      // it just hasn't happened. Don't let it drag today's ratio down before it's due.
      if (d.scheduledAt.isAfter(now)) continue;
      final day = DateTime(d.scheduledAt.year, d.scheduledAt.month, d.scheduledAt.day);
      final prev = out[day] ?? (taken: 0, total: 0);
      final counted = d.effectiveStatus(now) == DoseStatus.taken;
      out[day] = (taken: prev.taken + (counted ? 1 : 0), total: prev.total + 1);
    }
    return out;
  }
}
