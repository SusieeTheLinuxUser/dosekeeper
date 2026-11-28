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

  test('a dose in the spring-forward gap still matches its slot', () {
    // 02:30 does not exist on this day, so slot() shifts it. Comparing instants keeps
    // it a real dose instead of an orphan that gets deleted and never rings.
    const gapMed = Medication(
      id: 1,
      name: 'A',
      timesOfDay: [150],
      daysOfWeek: Medication.everyDay,
    );
    final at = DoseScheduler.slot(DateTime(2026, 3, 29), 150);

    expect(gapMed.coversSlot(at), isTrue);
  });

  test('a dose inside the fall-back repeated hour keeps its slot', () {
    // Warsaw 2026-10-25: 03:00 -> 02:00, so 02:30 happens twice. slot() resolves to
    // the first occurrence, and the instant must keep matching its slot through the
    // database round-trip (fromMillisecondsSinceEpoch, what Dose.fromRow does), or the
    // dose is rearmed an hour late on the second 02:30 -- or deleted as an orphan.
    const med = Medication(id: 1, name: 'A', timesOfDay: [150], daysOfWeek: Medication.everyDay);
    final at = DoseScheduler.slot(DateTime(2026, 10, 25), 150);

    expect(at.hour * 60 + at.minute, 150, reason: 'the wall clock stays 02:30');
    expect(med.coversSlot(at), isTrue);
    final fromDb = DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch);
    expect(med.coversSlot(fromDb), isTrue,
        reason: 'the stored instant still matches its slot');
    expect(fromDb.millisecondsSinceEpoch, at.millisecondsSinceEpoch,
        reason: 'no hour lost or gained storing the instant');
  });

  test('occursOn maps ISO weekdays with no off-by-one across the whole week', () {
    // Nov 9 2026 is a Monday, so Nov 9..15 walk Monday..Sunday.
    for (var medDay = 1; medDay <= 7; medDay++) {
      final med = Medication(id: 1, name: 'A', timesOfDay: [540], daysOfWeek: {medDay});
      for (var day = 0; day < 7; day++) {
        final date = DateTime(2026, 11, 9 + day);
        expect(med.occursOn(date), date.weekday == medDay,
            reason: 'med on ISO day $medDay vs ${date.weekday} of $date');
      }
    }
  });

  test('a late slot pushed past midnight by the gap still matches its slot', () {
    // Only in a zone whose gap starts at 23:00, e.g. TZ=America/Nuuk on 2026-03-28.
    final saturday = DateTime(2026, 3, 28);
    final at = DoseScheduler.slot(saturday, 1410);
    if (at.day == saturday.day) return markTestSkipped('no gap at 23:30 in this zone');
    const satMed = Medication(id: 1, name: 'A', timesOfDay: [1410], daysOfWeek: {6});

    expect(satMed.coversSlot(at), isTrue);
  });

  test('slot keeps midnight and 23:59 on their own day, including December 31', () {
    final midnight = DoseScheduler.slot(DateTime(2026, 12, 31), 0);
    expect(
      (midnight.year, midnight.month, midnight.day, midnight.hour, midnight.minute),
      (2026, 12, 31, 0, 0),
    );

    final lastMinute = DoseScheduler.slot(DateTime(2026, 12, 31), 1439);
    expect(
      (lastMinute.year, lastMinute.month, lastMinute.day, lastMinute.hour, lastMinute.minute),
      (2026, 12, 31, 23, 59),
    );
  });

  test('slot lands on the leap day itself and the day after it', () {
    final leap = DoseScheduler.slot(DateTime(2028, 2, 29), 540);
    expect((leap.year, leap.month, leap.day, leap.hour), (2028, 2, 29, 9));

    // slot() takes the day from the passed DateTime, so Feb 28 stays Feb 28.
    final before = DoseScheduler.slot(DateTime(2028, 2, 28), 540);
    expect((before.year, before.month, before.day, before.hour), (2028, 2, 28, 9));
  });

  test('a weekday-only med covers the first minutes after its own midnight', () {
    // Monday, 9 Nov 2026, 00:30.
    const monMed = Medication(id: 1, name: 'A', timesOfDay: [30], daysOfWeek: {1});

    expect(monMed.coversSlot(DateTime(2026, 11, 9, 0, 30)), isTrue);
    // Tuesday 00:30 is neither Tuesday's time nor Monday's.
    expect(monMed.coversSlot(DateTime(2026, 11, 10, 0, 30)), isFalse);
  });

  test('coversSlot works across a month end and a leap day boundary', () {
    const med = Medication(id: 1, name: 'A', timesOfDay: [540], daysOfWeek: Medication.everyDay);

    expect(med.coversSlot(DateTime(2026, 3, 1, 9)), isTrue); // March 1 after a month end
    expect(med.coversSlot(DateTime(2028, 2, 29, 9)), isTrue); // the leap day itself
    expect(med.coversSlot(DateTime(2028, 3, 1, 9)), isTrue); // the day after it
  });
}
