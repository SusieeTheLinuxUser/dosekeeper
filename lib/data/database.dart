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
      version: 1,
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
            UNIQUE (medication_id, scheduled_at),
            FOREIGN KEY (medication_id) REFERENCES medications (id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_doses_scheduled ON doses (scheduled_at)',
        );
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
