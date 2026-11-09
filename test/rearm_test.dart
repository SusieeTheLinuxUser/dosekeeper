import 'dart:io';

import 'package:dosekeeper/data/database.dart';
import 'package:dosekeeper/models/medication.dart';
import 'package:dosekeeper/services/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// What Android's background sync (BackgroundSync.kt -> DoseScheduler.sync) must
// re-arm. Each test runs sync() against a real SQLite database (via sqflite FFI)
// with the native alarm channel faked out, recording what would be armed/cancelled.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fake native alarm state, read and written by the mock channel handler.
  var armed = <int, int>{}; // doseId -> triggerAt millis
  var cancelled = <int>[];
  var scheduleCalls = 0;
  var pendingActions = <Map<String, dynamic>>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Temp databases path, so nothing touches a real one.
    await databaseFactory.setDatabasesPath(
        (await Directory.systemTemp.createTemp('dosekeeper_rearm_test')).path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.susiee.dosekeeper/alarms'),
      (call) async {
        final args = call.arguments is Map
            ? Map<Object?, Object?>.from(call.arguments as Map)
            : const {};
        switch (call.method) {
          case 'scheduleDose':
            scheduleCalls++;
            armed[args['doseId'] as int] = (args['triggerAt'] as num).toInt();
            return true;
          case 'cancelDose':
            final id = args['doseId'] as int;
            armed.remove(id);
            cancelled.add(id);
            return null;
          case 'drainPendingActions':
            final out = pendingActions;
            pendingActions = [];
            return out;
          case 'drainFiredEvents':
            return [];
          case 'outstandingDismissedThrough':
            return 0;
          default:
            return null;
        }
      },
    );
  });

  setUp(() async {
    armed = {};
    cancelled = [];
    scheduleCalls = 0;
    pendingActions = [];
    // DoseDatabase is a singleton; isolate tests by clearing its rows instead
    // of re-opening at a new path.
    final conn = await DoseDatabase.instance.database;
    await conn.delete('doses');
    await conn.delete('medications');
  });

  Future<int> addMed({
    List<int> timesOfDay = const [540], // 09:00
    Set<int> daysOfWeek = Medication.everyDay,
  }) async =>
      await DoseDatabase.instance.upsertMedication(Medication(
            name: 'Test med',
            timesOfDay: timesOfDay,
            daysOfWeek: daysOfWeek,
          ));

  final db = DoseDatabase.instance;
  final scheduler = DoseScheduler();
  int ms(DateTime t) => t.millisecondsSinceEpoch;

  test('top-up past the old window arms a dose beyond 3 days', () async {
    await addMed();
    // Day 0 (Mon Nov 2): only days 0..3 are materialised and armed.
    await scheduler.sync(now: DateTime(2026, 11, 2, 10, 0));
    expect(armed.values.any((t) => t >= ms(DateTime(2026, 11, 6, 9, 0))), isFalse,
        reason: 'nothing beyond the 3-day horizon can be armed from day 0');
    // Day 5: the window slid to days 5..8, so day 7 09:00 must be armed now.
    await scheduler.sync(now: DateTime(2026, 11, 7, 10, 0));
    expect(armed.containsValue(ms(DateTime(2026, 11, 9, 9, 0))), isTrue,
        reason: 'day 7 09:00 (5 days past day 0) must be re-armed');
  });

  test('weekly med armed only once its next occurrence is within horizon', () async {
    await addMed(daysOfWeek: {1}); // Mondays
    // One sync per day, Tue Nov 10 .. Tue Nov 17. Next Monday is Nov 16:
    // inside [now, now + 3 days) only from Fri Nov 13 on.
    for (var i = 0; i < 8; i++) {
      await scheduler.sync(now: DateTime(2026, 11, 10 + i, 10, 0));
      expect(armed.containsValue(ms(DateTime(2026, 11, 16, 9, 0))), i >= 3,
          reason: 'day offset $i: Nov 16 crosses into the horizon at Nov 13');
    }
  });

  test('a moved-wall-clock dose off its slot is cancelled, deleted, replaced', () async {
    final medId = await addMed();
    // A future pending dose an hour off the 09:00 slot -- what a time-zone
    // change leaves behind. Native already armed it, so record that.
    final movedId = await db.ensureDose(medId, DateTime(2026, 11, 10, 10, 0));
    armed[movedId!] = ms(DateTime(2026, 11, 10, 10, 0));
    await scheduler.sync(now: DateTime(2026, 11, 9, 12, 0));
    expect(cancelled, contains(movedId));
    expect(await db.dose(movedId), isNull,
        reason: 'the off-slot dose row must be gone');
    expect(armed.containsKey(movedId), isFalse);
    expect(armed.containsValue(ms(DateTime(2026, 11, 10, 9, 0))), isTrue,
        reason: 'the correct 09:00 dose is armed instead');
  });

  test('three syncs with the same now never double-arm', () async {
    await addMed();
    final now = DateTime(2026, 11, 9, 10, 0);
    for (var i = 0; i < 3; i++) {
      await scheduler.sync(now: now);
    }
    final window = await db.dosesBetween(now, now.add(DoseScheduler.horizon));
    final pendingIds =
        window.where((d) => d.status == DoseStatus.pending).map((d) => d.id).toSet();
    expect(armed.keys.toSet(), pendingIds,
        reason: 'one armed alarm per pending dose in the window, no extras');
    expect(armed.length, pendingIds.length);
    expect(armed.values.toSet().length, armed.length,
        reason: 'each dose id has exactly one trigger time');
    expect(scheduleCalls, pendingIds.length * 3,
        reason: 'each sync re-arms each dose exactly once');
  });

  test('a pending dose a minute past due is not re-armed, cancelled or deleted', () async {
    final medId = await addMed();
    // 09:00 dose, sync at 09:01: the alarm just fired (or was snoozed) and the
    // user hasn't answered yet. Nothing must touch it.
    final id = await db.ensureDose(medId, DateTime(2026, 11, 9, 9, 0));
    await scheduler.sync(now: DateTime(2026, 11, 9, 9, 1));
    expect(armed.containsKey(id), isFalse,
        reason: 'a passed dose must not get a scheduleDose call');
    expect(cancelled, isNot(contains(id)));
    expect((await db.dose(id!))?.status, DoseStatus.pending,
        reason: 'still pending, not deleted');
  });

  test('a queued TAKEN action marks the dose and keeps it unarmed', () async {
    final medId = await addMed();
    final now = DateTime(2026, 11, 9, 8, 0);
    final id = await db.ensureDose(medId, DateTime(2026, 11, 9, 9, 0));
    pendingActions = [
      {'doseId': id, 'action': 'TAKEN', 'at': ms(DateTime(2026, 11, 9, 9, 0))},
    ];
    await scheduler.sync(now: now);
    expect((await db.dose(id!))?.status, DoseStatus.taken);
    expect(armed.containsKey(id), isFalse,
        reason: 'a taken dose must not get an alarm');
  });
}