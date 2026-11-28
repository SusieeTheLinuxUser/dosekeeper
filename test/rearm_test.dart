import 'dart:io';

import 'package:dosekeeper/data/database.dart';
import 'package:dosekeeper/models/medication.dart';
import 'package:dosekeeper/services/backup_format.dart';
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
  var statusAtAck = <int, DoseStatus?>{}; // what the database held when acked
  var firedEvents = <Map<String, dynamic>>[];
  var firedAtWhenAck = <int, DateTime?>{};

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
          case 'readPendingActions':
            return pendingActions;
          case 'ackPendingAction':
            final id = args['doseId'] as int;
            statusAtAck[id] = (await DoseDatabase.instance.dose(id))?.status;
            pendingActions = [
              for (final a in pendingActions)
                if (a['doseId'] != id || a['at'] != args['at']) a,
            ];
            return true;
          case 'readFiredEvents':
            return firedEvents;
          case 'ackFiredEvent':
            final id = args['doseId'] as int;
            firedAtWhenAck[id] = (await DoseDatabase.instance.dose(id))?.firedAt;
            firedEvents = [
              for (final e in firedEvents)
                if (e['doseId'] != id || e['firedAt'] != args['firedAt']) e,
            ];
            return true;
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
    statusAtAck = {};
    firedEvents = [];
    firedAtWhenAck = {};
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

  test('a Taken record is removed only after the database has it', () async {
    final medId = await addMed();
    final id = await db.ensureDose(medId, DateTime(2026, 11, 9, 9, 0));
    pendingActions = [
      {'doseId': id, 'action': 'TAKEN', 'at': ms(DateTime(2026, 11, 9, 9, 0))},
    ];
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 0));
    expect(statusAtAck[id], DoseStatus.taken,
        reason: 'acked before the status was saved, a dying sync would lose it');
    expect(pendingActions, isEmpty);
  });

  test('a record for a dose that no longer exists is cleared, not kept forever', () async {
    pendingActions = [
      {'doseId': 987654, 'action': 'TAKEN', 'at': ms(DateTime(2026, 11, 9, 9, 0))},
    ];
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 0));
    expect(pendingActions, isEmpty);
  });

  test('a fired event is saved before native storage is acknowledged', () async {
    final medId = await addMed();
    final id = await db.ensureDose(medId, DateTime(2026, 11, 9, 9, 0));
    final firedAt = DateTime(2026, 11, 9, 9, 0, 2);
    firedEvents = [
      {'doseId': id, 'firedAt': ms(firedAt)},
    ];

    await scheduler.sync(now: DateTime(2026, 11, 9, 9, 1));

    expect((await db.dose(id!))?.firedAt, firedAt);
    expect(firedAtWhenAck[id], firedAt,
        reason: 'if SQLite fails before this point, the native event must remain');
    expect(firedEvents, isEmpty);
  });

  test('a fired event for a missing dose is acknowledged', () async {
    firedEvents = [
      {'doseId': 987654, 'firedAt': ms(DateTime(2026, 11, 9, 9, 0))},
    ];

    await scheduler.sync(now: DateTime(2026, 11, 9, 9, 1));

    expect(firedEvents, isEmpty);
  });

  Future<List<DateTime>> pendingTimes(DateTime from, DateTime to) async =>
      (await db.dosesBetween(from, to))
          .where((d) => d.status == DoseStatus.pending)
          .map((d) => d.scheduledAt)
          .toList();

  test('doses are materialised and armed across a month end', () async {
    await addMed(); // 09:00 daily
    // Days 0..3 from Jan 30 are Jan 30, 31, Feb 1, Feb 2.
    await scheduler.sync(now: DateTime(2026, 1, 30, 10, 0));

    expect(
      await pendingTimes(DateTime(2026, 1, 30), DateTime(2026, 2, 3)),
      [DateTime(2026, 1, 30, 9, 0), DateTime(2026, 1, 31, 9, 0),
          DateTime(2026, 2, 1, 9, 0), DateTime(2026, 2, 2, 9, 0)],
    );
    // Jan 30 09:00 was back-filled one hour into the past (it never had an
    // alarm), so only the three future days get alarms.
    for (final day in [DateTime(2026, 1, 31), DateTime(2026, 2, 1), DateTime(2026, 2, 2)]) {
      expect(armed.containsValue(ms(day.add(const Duration(hours: 9)))), isTrue,
          reason: '${day.toIso8601String()} 09:00 must be armed');
    }
    expect(armed.containsValue(ms(DateTime(2026, 1, 30, 9, 0))), isFalse,
        reason: 'a back-filled past dose is never armed');
  });

  test('the leap day itself is materialised', () async {
    await addMed();
    // Days 0..3 from Feb 27 2028 (a leap year) are Feb 27, 28, 29, Mar 1.
    await scheduler.sync(now: DateTime(2028, 2, 27, 10, 0));

    expect(
      await pendingTimes(DateTime(2028, 2, 27), DateTime(2028, 3, 2)),
      [DateTime(2028, 2, 27, 9, 0), DateTime(2028, 2, 28, 9, 0),
          DateTime(2028, 2, 29, 9, 0), DateTime(2028, 3, 1, 9, 0)],
    );
  });

  test('a Monday-only med gets doses only on Mondays', () async {
    await addMed(daysOfWeek: {1}); // Mondays
    // Friday Nov 6 .. Monday Nov 9 (day offset 3).
    await scheduler.sync(now: DateTime(2026, 11, 6, 12, 0));

    expect(await pendingTimes(DateTime(2026, 11, 6), DateTime(2026, 11, 10)),
        [DateTime(2026, 11, 9, 9, 0)],
        reason: 'only Monday Nov 9 is on the schedule');
    expect(armed.containsValue(ms(DateTime(2026, 11, 9, 9, 0))), isTrue);
  });

  test('the last materialised evening is created but armed a day later', () async {
    await addMed(timesOfDay: [1410]); // 23:30
    // Window [Nov 9 00:30, Nov 12 00:30): Nov 12's 23:30 is materialised
    // (day offset 3) but lies beyond it, so it must not be armed yet.
    await scheduler.sync(now: DateTime(2026, 11, 9, 0, 30));
    final late = await db.dosesBetween(DateTime(2026, 11, 12), DateTime(2026, 11, 13));
    expect(late, hasLength(1));
    expect(armed.containsKey(late.single.id), isFalse);

    await scheduler.sync(now: DateTime(2026, 11, 10, 0, 30));
    expect(armed.containsKey(late.single.id), isTrue,
        reason: 'a day later it is inside the window and must be armed');
  });

  test('a med added now gets a dose for a time 1h ago, but not one 13h ago', () async {
    await addMed(timesOfDay: [480, 960]); // 08:00, 16:00
    await scheduler.sync(now: DateTime(2026, 11, 9, 21, 0));

    expect(await pendingTimes(DateTime(2026, 11, 9), DateTime(2026, 11, 10)),
        [DateTime(2026, 11, 9, 16, 0)],
        reason: 'the 12h back-fill covers 16:00 (5h ago), not 08:00 (13h ago)');
  });

  test('editing days out of a med cancels their doses but keeps the kept day',
      () async {
    final medId = await addMed(); // 09:00 daily
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 0)); // a Monday
    final tuesday =
        (await db.dosesBetween(DateTime(2026, 11, 10), DateTime(2026, 11, 11))).single;
    expect(armed.containsKey(tuesday.id), isTrue, reason: 'precondition: Tuesday armed');

    await db.upsertMedication(Medication(
        id: medId,
        name: 'Test med',
        timesOfDay: [540],
        daysOfWeek: {1})); // Mondays only
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 30));

    expect(cancelled, contains(tuesday.id), reason: 'Tuesday is no longer scheduled');
    expect(await db.dose(tuesday.id!), isNull, reason: 'the unscheduled dose row is deleted');
    expect(armed.keys, hasLength(1),
        reason: 'only Monday Nov 9 stays armed -- none doubled, none left over');
  });

  test('duplicate and unsorted times never double a dose or its alarm', () async {
    // Constructed unsorted with a duplicate -- the shape a hand-repaired backup
    // row could arrive in. fromRow sorts and materialise is idempotent per
    // instant, so the duplicate must collapse into one dose with one alarm.
    await DoseDatabase.instance.upsertMedication(Medication(
      name: 'Test med',
      timesOfDay: const [600, 540, 540], // 10:00, 09:00, 09:00 again
      daysOfWeek: Medication.everyDay,
    ));
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 0));

    final day = await db.dosesBetween(DateTime(2026, 11, 10), DateTime(2026, 11, 11));
    expect(day.map((d) => d.scheduledAt),
        [DateTime(2026, 11, 10, 9, 0), DateTime(2026, 11, 10, 10, 0)],
        reason: 'one dose per instant, in slot order, no 09:00 double');
    expect(
      armed.values.where((t) => t == ms(DateTime(2026, 11, 10, 9, 0))),
      hasLength(1),
      reason: 'one alarm for the duplicated 09:00 instant',
    );
  });

  test('a midnight dose is armed the evening before, and 23:59 the same evening',
      () async {
    await addMed(timesOfDay: [0]); // 00:00
    // Sunday evening: Monday 00:00 is 4h ahead and must already be armed, so
    // the day rolling over cannot find it unarmed.
    await scheduler.sync(now: DateTime(2026, 11, 8, 20, 0)); // Nov 8 is a Sunday
    expect(armed.containsValue(ms(DateTime(2026, 11, 9, 0, 0))), isTrue,
        reason: 'the midnight dose is armed before the day rolls over');

    await addMed(timesOfDay: [1439]); // 23:59
    await scheduler.sync(now: DateTime(2026, 11, 8, 20, 0));
    expect(armed.containsValue(ms(DateTime(2026, 11, 8, 23, 59))), isTrue,
        reason: 'a 23:59 dose the same evening is armed while still today');
  });

  test('editing a time out of a med cancels its armed alarm and deletes the dose',
      () async {
    final medId = await addMed(timesOfDay: [540, 600]); // 09:00, 10:00
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 0));
    final removed = (await db.dosesBetween(DateTime(2026, 11, 10), DateTime(2026, 11, 11)))
        .firstWhere((d) => d.scheduledAt.hour == 10);
    expect(armed.containsKey(removed.id), isTrue, reason: 'precondition: it was armed');

    await db.upsertMedication(Medication(
        id: medId, name: 'Test med', timesOfDay: [540], daysOfWeek: Medication.everyDay));
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 30));

    expect(cancelled, contains(removed.id));
    expect(await db.dose(removed.id!), isNull, reason: 'the orphaned dose row is deleted');
    expect(armed.containsKey(removed.id), isFalse);
    expect(armed.containsValue(ms(DateTime(2026, 11, 10, 9, 0))), isTrue,
        reason: 'the kept 09:00 dose stays armed');
  });

  test('deleting a med cancels its still-armed alarms', () async {
    final medId = await addMed();
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 0));
    expect(armed, isNotEmpty, reason: 'precondition: its doses were armed');

    await db.deleteMedication(medId);
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 30));

    expect(armed, isEmpty, reason: 'every armed alarm belonged to the deleted med');
    // Doses past [now, now + 3 days) (here Nov 12 09:00, 30 min beyond the
    // window) were never armed and go with the next sync's window slide.
    expect(await pendingTimes(DateTime(2026, 11, 9), DateTime(2026, 11, 12, 8, 30)),
        isEmpty, reason: 'its future pending doses inside the window are gone');
  });

  test('restore cancels old alarms, lands the backup, and arms the restored schedule',
      () async {
    await addMed(); // 09:00 daily
    await scheduler.sync(now: DateTime(2026, 11, 9, 8, 0));
    final oldIds = List<int>.of(armed.keys);
    expect(oldIds, isNotEmpty, reason: 'precondition: the old schedule was armed');

    final backup = Backup(
      exportedAt: DateTime(2026, 11, 9, 8, 0),
      medications: const [
        Medication(id: 1, name: 'Restored', timesOfDay: [600], daysOfWeek: Medication.everyDay),
      ],
      doses: [
        Dose(
          medicationId: 1,
          scheduledAt: DateTime(2026, 11, 8, 10, 0),
          status: DoseStatus.taken,
          actionedAt: DateTime(2026, 11, 8, 10, 5),
        ),
      ],
    );
    await scheduler.restore(backup, now: DateTime(2026, 11, 9, 8, 30));

    expect(cancelled, containsAll(oldIds), reason: 'old alarms must not survive');
    expect(armed.containsValue(ms(DateTime(2026, 11, 9, 9, 0))), isFalse,
        reason: 'the old 09:00 schedule is gone');
    expect(armed.containsValue(ms(DateTime(2026, 11, 10, 10, 0))), isTrue,
        reason: 'the restored 10:00 schedule is armed');
    expect((await db.medications()).single.name, 'Restored');
    final history = await db.allDoses();
    expect(history.where((d) => d.status == DoseStatus.taken), hasLength(1),
        reason: 'the backup dose history is kept');
  });

  test('time-window queries are half-open: from inclusive, to exclusive', () async {
    final medId = await addMed();
    final id = await db.ensureDose(medId, DateTime(2026, 11, 9, 9, 0));

    expect((await db.dosesBetween(DateTime(2026, 11, 9, 9, 0), DateTime(2026, 11, 9, 9, 1)))
        .map((d) => d.id), [id], reason: 'scheduled == from is included');
    expect(await db.dosesBetween(DateTime(2026, 11, 9, 8, 0), DateTime(2026, 11, 9, 9, 0)),
        isEmpty, reason: 'scheduled == to is excluded');
    expect(await db.pendingDosesBefore(DateTime(2026, 11, 9, 9, 0)), isEmpty,
        reason: 'scheduled == cutoff is excluded');
    expect(
        (await db.upcomingPendingDoses(DateTime(2026, 11, 9, 9, 0), DateTime(2026, 11, 10)))
            .map((d) => d.id),
        [id], reason: 'scheduled == now is included');
    expect(await db.upcomingPendingDoses(DateTime(2026, 11, 9, 9, 1), DateTime(2026, 11, 10)),
        isEmpty, reason: 'scheduled < now is excluded');
  });

  test('ensureDose never duplicates or overwrites an answered dose', () async {
    final medId = await addMed();
    final id = await db.ensureDose(medId, DateTime(2026, 11, 9, 9, 0));
    await db.setDoseStatus(id!, DoseStatus.taken, at: DateTime(2026, 11, 9, 9, 30));

    // The conflict-ignored insert returns null on Android's sqflite and 0 on the
    // FFI one; its value is unused -- what matters is the single, answered row.
    await db.ensureDose(medId, DateTime(2026, 11, 9, 9, 0));
    final all = await db.dosesBetween(DateTime(2026, 11, 9), DateTime(2026, 11, 10));
    expect(all, hasLength(1));
    expect(all.single.status, DoseStatus.taken);
  });

  test('setDoseFiredAt keeps the first ring time', () async {
    final medId = await addMed();
    final id = await db.ensureDose(medId, DateTime(2026, 11, 9, 9, 0));
    await db.setDoseFiredAt(id!, DateTime(2026, 11, 9, 9, 0, 2));
    await db.setDoseFiredAt(id, DateTime(2026, 11, 9, 9, 10, 2));

    expect((await db.dose(id))?.firedAt, DateTime(2026, 11, 9, 9, 0, 2),
        reason: 'a snoozed re-fire must not overwrite the first ring');
  });

  test('dailyAdherence counts a future dose as neither taken nor total', () async {
    final medId = await addMed();
    final now = DateTime.now();
    // Midnight today is always in today's bucket, whatever time it is now.
    final takenId = await db.ensureDose(medId, DateTime(now.year, now.month, now.day));
    await db.setDoseStatus(takenId!, DoseStatus.taken);
    final futureId = await db.ensureDose(medId, now.add(const Duration(hours: 1)));
    expect(futureId, isNotNull);

    final counts = await db.dailyAdherence(
        now.subtract(const Duration(days: 1)), now.add(const Duration(days: 1)));

    // The whole map: after 23:00 the future dose falls tomorrow, and it must
    // not show up there either.
    expect(counts, {DateTime(now.year, now.month, now.day): (taken: 1, total: 1)},
        reason: 'a dose that has not come due yet must not be counted');
  });
}
