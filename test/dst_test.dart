import 'package:dosekeeper/models/medication.dart';
import 'package:dosekeeper/services/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

// Only bites in a timezone with DST: CI runs the suite with TZ=Europe/Warsaw.
void main() {
  const med = Medication(id: 1, name: 'A', timesOfDay: [480, 1410], daysOfWeek: Medication.everyDay);

  test('a dose keeps its wall-clock time on the days the clocks change', () {
    for (final day in [DateTime(2026, 3, 29), DateTime(2026, 10, 25)]) {
      for (final minutes in med.timesOfDay) {
        final at = DoseScheduler.slot(day, minutes);
        expect((at.year, at.month, at.day), (day.year, day.month, day.day));
        expect(at.hour * 60 + at.minute, minutes);
        // A dose off its slot would be deleted as an orphan and never ring.
        expect(med.coversSlot(at), isTrue);
      }
    }
  });
}
