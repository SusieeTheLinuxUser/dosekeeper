import 'package:flutter_test/flutter_test.dart';

import 'package:dosekeeper/models/medication.dart';

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
  });
}
