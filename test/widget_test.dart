import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:dosekeeper/data/database.dart';
import 'package:dosekeeper/models/medication.dart';
import 'package:dosekeeper/services/alarm_bridge.dart';
import 'package:dosekeeper/services/scheduler.dart';
import 'package:dosekeeper/ui/adherence_grid.dart';
import 'package:dosekeeper/ui/backup_page.dart';
import 'package:dosekeeper/ui/info_page.dart';
import 'package:dosekeeper/ui/medication_edit_page.dart';
import 'package:dosekeeper/ui/medications_page.dart';
import 'package:dosekeeper/ui/today_page.dart';

void main() {
  group('Medication', () {
    test('survives a database round-trip', () {
      const med = Medication(
        id: 7,
        name: 'Sertraline',
        dosage: '50mg',
        timesOfDay: [480, 1260], // 08:00, 21:00
        daysOfWeek: {1, 3, 5},
        notes: 'with food',
      );

      final restored = Medication.fromRow(med.toRow());

      expect(restored.id, 7);
      expect(restored.name, 'Sertraline');
      expect(restored.dosage, '50mg');
      expect(restored.timesOfDay, [480, 1260]);
      expect(restored.daysOfWeek, {1, 3, 5});
      expect(restored.notes, 'with food');
    });

    test('only occurs on its configured weekdays', () {
      const med = Medication(
        name: 'Weekdays only',
        timesOfDay: [540],
        daysOfWeek: {1, 2, 3, 4, 5},
      );

      expect(med.occursOn(DateTime(2026, 9, 21)), isTrue); // Monday
      expect(med.occursOn(DateTime(2026, 9, 26)), isFalse); // Saturday
    });

    test('coversSlot is true for a time and day the medication still lists', () {
      const med = Medication(
        name: 'Meds',
        timesOfDay: [1290], // 21:30
        daysOfWeek: {1, 2, 3, 4, 5, 6, 7},
      );

      expect(med.coversSlot(DateTime(2026, 9, 23, 21, 30)), isTrue);
    });

    test('coversSlot is false for a time removed from the schedule -- the exact bug '
        'that left a real alarm armed for a time no longer in any medication', () {
      const med = Medication(
        name: 'Meds',
        timesOfDay: [1290], // 21:30 only, 09:30 was removed
        daysOfWeek: {1, 2, 3, 4, 5, 6, 7},
      );

      expect(med.coversSlot(DateTime(2026, 9, 23, 9, 30)), isFalse);
    });

    test('coversSlot is false for an inactive medication even at a listed time', () {
      const med = Medication(
        name: 'Paused',
        timesOfDay: [540],
        daysOfWeek: {1, 2, 3, 4, 5, 6, 7},
        active: false,
      );

      expect(med.coversSlot(DateTime(2026, 9, 23, 9, 0)), isFalse);
    });
  });

  group('Dose', () {
    final scheduled = DateTime(2026, 9, 21, 8, 0);

    test('stays pending inside the grace period', () {
      final dose = Dose(medicationId: 1, scheduledAt: scheduled);
      final justAfter = scheduled.add(const Duration(minutes: 30));

      expect(dose.effectiveStatus(justAfter), DoseStatus.pending);
    });

    test('counts as missed once the grace period lapses', () {
      final dose = Dose(medicationId: 1, scheduledAt: scheduled);
      final wellAfter = scheduled.add(const Duration(hours: 3));

      expect(dose.effectiveStatus(wellAfter), DoseStatus.missed);
    });

    test('a taken dose never becomes missed, however late the check', () {
      final dose = Dose(
        medicationId: 1,
        scheduledAt: scheduled,
        status: DoseStatus.taken,
        actionedAt: scheduled,
      );

      expect(
        dose.effectiveStatus(scheduled.add(const Duration(days: 5))),
        DoseStatus.taken,
      );
    });

    test('firedAt survives a database round-trip', () {
      final firedAt = scheduled.add(const Duration(seconds: 2));
      final dose = Dose(
        id: 3,
        medicationId: 1,
        scheduledAt: scheduled,
        firedAt: firedAt,
      );

      final restored = Dose.fromRow(dose.toRow());

      expect(restored.firedAt, firedAt);
    });

    test('firedAt is null for a dose that has never rung', () {
      final dose = Dose(medicationId: 1, scheduledAt: scheduled);

      expect(Dose.fromRow(dose.toRow()).firedAt, isNull);
    });
  });

  group('DoseScheduler.undiscardedMissed', () {
    final seven = DateTime(2026, 11, 2, 7);
    final dose = Dose(medicationId: 1, scheduledAt: seven);
    final never = DateTime.fromMillisecondsSinceEpoch(0);

    test('a missed dose notifies until the notification is swiped away', () {
      final now = DateTime(2026, 11, 4, 12);
      expect(DoseScheduler.undiscardedMissed([dose], now, never), [dose]);
      final swiped = seven.add(const Duration(hours: 3));
      expect(DoseScheduler.undiscardedMissed([dose], now, swiped), isEmpty);
    });

    test('a dose missed after the swipe still notifies', () {
      final swiped = seven.add(const Duration(hours: 1)); // inside its grace period
      final now = seven.add(const Duration(hours: 3));
      expect(DoseScheduler.undiscardedMissed([dose], now, swiped), [dose]);
    });

    test('a dose still in its grace period does not notify', () {
      final now = seven.add(const Duration(hours: 1));
      expect(DoseScheduler.undiscardedMissed([dose], now, never), isEmpty);
    });
  });

  group('DoseScheduler.singleActionableDoseId', () {
    final dose = Dose(id: 42, medicationId: 1, scheduledAt: DateTime(2026, 11, 2, 7));

    test('exactly one missed dose gets the notification buttons', () {
      expect(DoseScheduler.singleActionableDoseId([dose]), 42);
    });

    test('two or more missed doses get no buttons -- one tap must not mark several', () {
      final other =
          Dose(id: 43, medicationId: 2, scheduledAt: DateTime(2026, 11, 2, 8));
      expect(DoseScheduler.singleActionableDoseId([dose, other]), isNull);
      expect(DoseScheduler.singleActionableDoseId([]), isNull);
    });

    test('an unsaved dose (no id yet) gets no buttons', () {
      expect(
        DoseScheduler.singleActionableDoseId(
          [Dose(medicationId: 1, scheduledAt: DateTime(2026, 11, 2, 7))],
        ),
        isNull,
      );
    });
  });

  test('a SKIPPED outcome from the notification parses like the alarm screen\'s TAKEN',
      () {
    final skipped = PendingAlarmAction.fromMap(
        {'doseId': 5, 'action': 'SKIPPED', 'at': 1000});
    expect(skipped.isSkipped, isTrue);
    expect(skipped.isTaken, isFalse);
    final taken =
        PendingAlarmAction.fromMap({'doseId': 6, 'action': 'TAKEN', 'at': 1000});
    expect(taken.isTaken, isTrue);
    expect(taken.isSkipped, isFalse);
  });

  group('AdherenceGrid.mondayOf', () {
    test('steps back to Monday from mid-week', () {
      expect(AdherenceGrid.mondayOf(DateTime(2026, 9, 24)), DateTime(2026, 9, 21)); // Thu -> Mon
    });

    test('leaves a Monday unchanged', () {
      expect(AdherenceGrid.mondayOf(DateTime(2026, 9, 21)), DateTime(2026, 9, 21));
    });

    test('steps back across a month boundary from Sunday', () {
      expect(AdherenceGrid.mondayOf(DateTime(2026, 10, 4)), DateTime(2026, 9, 28)); // Sun -> Mon
    });
  });

  testWidgets('the info page opens the source link, and hides its joke behind 10 taps',
      (tester) async {
    final opened = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.susiee.dosekeeper/alarms'),
      (call) async {
        if (call.method == 'appVersion') return '1.2.3-debug';
        if (call.method == 'openUrl') opened.add((call.arguments as Map)['url']);
        return true;
      },
    );
    await tester.pumpWidget(const MaterialApp(home: InfoPage()));
    await tester.pump();
    expect(find.text('1.2.3-debug'), findsOneWidget);

    await tester.tap(find.text('Source code'));
    await tester.pump();
    expect(opened, [InfoPage.sourceUrl]);

    for (var i = 0; i < 9; i++) {
      await tester.tap(find.text('Version'));
      await tester.pump();
    }
    expect(find.textContaining(RegExp('nobody came|Dio')), findsNothing);

    await tester.tap(find.text('Version'));
    await tester.pump();
    expect(find.textContaining(RegExp('nobody came|Dio')), findsOneWidget);
  });

  testWidgets('an alarm Android refused reads as not armed', (tester) async {
    Object? reply = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.susiee.dosekeeper/alarms'),
      (call) async => reply,
    );
    Future<bool> arm() => AlarmBridge.scheduleDose(
        doseId: 1, triggerAt: DateTime(2030), medName: 'Meds', dosage: '');
    expect(await arm(), isFalse);
    reply = null;
    expect(await arm(), isFalse);
    reply = true;
    expect(await arm(), isTrue);
  });

  test('the rare easter egg only appears below one in 10,000', () {
    expect(InfoPage.easterEgg(0), contains('Dio'));
    expect(InfoPage.easterEgg(1e-4), 'But nobody came...');
    expect(InfoPage.easterEgg(0.5), 'But nobody came...');
  });

  // These must stay above the Google backup test below: BackupService is a
  // singleton whose serial-run guard starts as a Future.value() created in
  // whatever zone first touches it. A future created in one widget test's fake
  // clock never fires listeners registered in a later test's clock (its zone is
  // dead by then), so if BackupPage is pumped first, every later TodayPage
  // refresh hangs forever in BackupService.backUpQuietly. This group's
  // "a dose tile reads..." test is the first caller, in its own zone.
  group('screen-reader labels', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      // Temp databases path, so nothing touches a real one (same as rearm_test).
      await databaseFactory.setDatabasesPath(
          (await Directory.systemTemp.createTemp('dosekeeper_a11y_test')).path);
    });

    setUp(() async {
      // DoseDatabase is a singleton; isolate tests by clearing its rows.
      final conn = await DoseDatabase.instance.database;
      await conn.delete('doses');
      await conn.delete('medications');
    });

    testWidgets('the delete button on a medication card is labelled',
        (tester) async {
      // runAsync: real database work can't progress inside the test's fake clock.
      await tester.runAsync(() => DoseDatabase.instance.upsertMedication(
          const Medication(
            name: 'Sertraline',
            timesOfDay: [540],
            daysOfWeek: Medication.everyDay,
          )));
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(home: MedicationsPage(scheduler: DoseScheduler())),
      );
      // The page loads its list from the database on the real event loop;
      // alternate real turns and fake-clock pumps until the card renders.
      for (var i = 0; i < 50 && find.byType(IconButton).evaluate().isEmpty; i++) {
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      expect(find.byType(IconButton), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(IconButton)).tooltip,
        'Delete medication',
      );
      expect(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('the save button on the medication editor is labelled',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const MaterialApp(home: MedicationEditPage()));
      await tester.pump();

      expect(find.byType(IconButton), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(IconButton)).tooltip,
        'Save medication',
      );
      expect(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('a dose tile reads the medicine, time and status together',
        (tester) async {
      // Everything refresh() touches outside the database is faked: the alarm
      // path answers "fine" so no warning card shows, and backups report a
      // folder so backups are on.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.susiee.dosekeeper/alarms'),
        (call) async => switch (call.method) {
              'scheduleDose' => true,
              'readPendingActions' => <Object?>[],
              'readFiredEvents' => <Object?>[],
              'outstandingDismissedThrough' => 0,
              'canScheduleExact' => true,
              'isIgnoringBatteryOptimizations' => true,
              'hasNotificationPermission' => true,
              'canUseFullScreenIntent' => true,
              'isBatteryLow' => false,
              'backupStatus' => <String, Object?>{'folderName': 'Backups'},
              _ => null,
            },
      );
      final handle = tester.ensureSemantics();
      // A dose marked taken: its tile shows the taken state no matter what
      // time the test runs at.
      await tester.runAsync(() async {
        final medId = await DoseDatabase.instance.upsertMedication(const Medication(
          name: 'Sertraline',
          timesOfDay: [540],
          daysOfWeek: Medication.everyDay,
        ));
        final now = DateTime.now();
        final doseId = await DoseDatabase.instance
            .ensureDose(medId, DateTime(now.year, now.month, now.day, 9));
        await DoseDatabase.instance.setDoseStatus(doseId!, DoseStatus.taken);
      });
      await tester.pumpWidget(
          MaterialApp(home: TodayPage(scheduler: DoseScheduler())));
      // The page syncs and loads from the database on the real event loop;
      // alternate real turns and fake-clock pumps until the dose tile renders.
      // sync() is a long sequential await chain, so allow many cycles.
      for (var i = 0; i < 400 && find.byType(ListTile).evaluate().isEmpty; i++) {
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      expect(find.byType(ListTile), findsOneWidget);
      final tile = tester.getSemantics(find.byType(ListTile));
      expect(tile.label, contains('Sertraline'));
      expect(tile.label, contains('09:00'));
      expect(tile.label, contains('Taken'));
      handle.dispose();
    });

    testWidgets('the day chips read as full day names', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const MaterialApp(home: MedicationEditPage()));
      await tester.pump();

      expect(
        tester.getSemantics(find.widgetWithText(ChoiceChip, 'M')).label,
        'Mon',
      );
      // The two single-letter "T" chips must be told apart by a screen reader.
      final tuesdays = find.widgetWithText(ChoiceChip, 'T');
      expect(tuesdays, findsNWidgets(2));
      expect(tester.getSemantics(tuesdays.first).label, 'Tue');
      expect(tester.getSemantics(tuesdays.last).label, 'Thu');
      handle.dispose();
    });
  });

  testWidgets('Google backup starts off, and the switch saves the choice', (tester) async {
    final saved = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.susiee.dosekeeper/alarms'),
      (call) async {
        if (call.method == 'backupStatus') return <String, Object?>{};
        if (call.method == 'googleBackupEnabled') return false;
        if (call.method == 'setGoogleBackupEnabled') {
          saved.add((call.arguments as Map)['enabled']);
        }
        return true;
      },
    );
    await tester.pumpWidget(MaterialApp(home: BackupPage(scheduler: DoseScheduler())));
    await tester.pump();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(saved, [true]);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
  });

  testWidgets('medication notes are available when editing', (tester) async {
    const med = Medication(
      id: 7,
      name: 'Meds',
      timesOfDay: [480],
      daysOfWeek: Medication.everyDay,
      notes: 'Take with food',
    );
    await tester.pumpWidget(
      const MaterialApp(home: MedicationEditPage(existing: med)),
    );

    final notesField = tester.widget<TextFormField>(
      find.byType(TextFormField).last,
    );
    expect(find.text('Notes (optional)'), findsOneWidget);
    expect(notesField.controller?.text, 'Take with food');
  });
}
