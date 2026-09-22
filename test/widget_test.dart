import 'package:flutter_test/flutter_test.dart';

import 'package:dosekeeper/models/medication.dart';
import 'package:dosekeeper/ui/adherence_grid.dart';

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
}
