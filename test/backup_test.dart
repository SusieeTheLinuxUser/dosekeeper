import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dosekeeper/models/medication.dart';
import 'package:dosekeeper/services/backup_format.dart';

void main() {
  final morning = DateTime(2026, 9, 21, 7);

  Backup sample() => Backup(
        exportedAt: DateTime(2026, 9, 24, 22, 10),
        medications: const [
          Medication(
            id: 6,
            name: 'Meds',
            dosage: '1 tablet',
            timesOfDay: [420], // 07:00
            daysOfWeek: Medication.everyDay,
            notes: 'with food',
          ),
          Medication(
            id: 7,
            name: 'Evening',
            timesOfDay: [1290], // 21:30
            daysOfWeek: {1, 3, 5},
            active: false,
          ),
        ],
        doses: [
          Dose(
            medicationId: 6,
            scheduledAt: morning,
            status: DoseStatus.taken,
            actionedAt: DateTime(2026, 9, 21, 19, 19),
            firedAt: morning,
          ),
          Dose(medicationId: 7, scheduledAt: DateTime(2026, 9, 21, 21, 30)),
        ],
      );

  /// Re-encodes [sample] after [edit] changes its raw JSON, for testing rejection.
  String tampered(void Function(Map<String, dynamic> json) edit) {
    final json = jsonDecode(sample().encode()) as Map<String, dynamic>;
    edit(json);
    return jsonEncode(json);
  }

  group('Backup', () {
    test('survives an encode/decode round-trip -- everything a restore needs', () {
      final restored = Backup.decode(sample().encode());

      expect(restored.exportedAt, DateTime(2026, 9, 24, 22, 10));
      expect(restored.medications, hasLength(2));
      final meds = restored.medications.first;
      expect(meds.id, 6);
      expect(meds.name, 'Meds');
      expect(meds.dosage, '1 tablet');
      expect(meds.timesOfDay, [420]);
      expect(meds.daysOfWeek, Medication.everyDay);
      expect(meds.notes, 'with food');
      expect(restored.medications.last.daysOfWeek, {1, 3, 5});
      expect(restored.medications.last.active, isFalse);

      final dose = restored.doses.first;
      expect(dose.medicationId, 6);
      expect(dose.scheduledAt, morning);
      expect(dose.status, DoseStatus.taken);
      expect(dose.actionedAt, DateTime(2026, 9, 21, 19, 19));
      expect(dose.firedAt, morning);
      expect(restored.doses.last.status, DoseStatus.pending);
      expect(restored.doses.last.actionedAt, isNull);
      expect(restored.doses.last.firedAt, isNull);
    });

    test('writes times as readable HH:mm and timestamps with their UTC offset', () {
      final json = jsonDecode(sample().encode()) as Map<String, dynamic>;

      expect((json['medications'] as List).first['times'], ['07:00']);
      expect(
        (json['doses'] as List).first['scheduledAt'] as String,
        matches(RegExp(r'^2026-09-21T07:00:00[+-]\d{2}:\d{2}$')),
      );
    });

    test('reads a timestamp from another timezone as the same instant', () {
      final t = Backup.parseTimestamp('2026-09-21T07:00:00+02:00');

      expect(t.isAtSameMomentAs(DateTime.utc(2026, 9, 21, 5)), isTrue);
    });

    test('rejects a file that is not JSON', () {
      expect(() => Backup.decode('hello'), throwsFormatException);
    });

    test('rejects JSON that is not a DoseKeeper backup', () {
      expect(() => Backup.decode('{"app": "something-else"}'), throwsFormatException);
    });

    test('rejects a backup from a newer format it cannot understand', () {
      expect(
        () => Backup.decode(tampered((j) => j['format'] = Backup.formatVersion + 1)),
        throwsFormatException,
      );
    });

    test('rejects a dose pointing at a medication the file does not contain', () {
      expect(
        () => Backup.decode(tampered((j) => (j['doses'] as List).first['medicationId'] = 99)),
        throwsFormatException,
      );
    });

    test('rejects a stored "missed" status -- missed is derived, never saved', () {
      expect(
        () => Backup.decode(tampered((j) => (j['doses'] as List).first['status'] = 'missed')),
        throwsFormatException,
      );
    });

    test('rejects an impossible time of day', () {
      expect(
        () => Backup.decode(
            tampered((j) => (j['medications'] as List).first['times'] = ['25:00'])),
        throwsFormatException,
      );
    });

    test('rejects a missing required field instead of restoring half a backup', () {
      expect(
        () => Backup.decode(tampered((j) => (j['medications'] as List).first.remove('name'))),
        throwsFormatException,
      );
    });
  });

  group('Backup files', () {
    test('one file per day, named by date', () {
      expect(Backup.fileNameFor(DateTime(2026, 9, 4, 23, 59)),
          'dosekeeper-backup-2026-09-04.json');
      expect(Backup.dayOf('dosekeeper-backup-2026-09-04.json'), '2026-09-04');
    });

    test('lists only its own files, newest first', () {
      expect(
        Backup.newestFirst([
          'dosekeeper-backup-2026-09-22.json',
          'holiday.jpg',
          'dosekeeper-backup-2026-09-24.json',
          'dosekeeper-backup-2026-09-24 (1).json',
          'dosekeeper-backup-2026-09-23.json',
        ]),
        [
          'dosekeeper-backup-2026-09-24.json',
          'dosekeeper-backup-2026-09-23.json',
          'dosekeeper-backup-2026-09-22.json',
        ],
      );
    });

    test('prunes only the oldest of its own files, never anything else', () {
      final names = [
        for (var day = 1; day <= 16; day++)
          Backup.fileNameFor(DateTime(2026, 9, day)),
        'notes.json',
      ];

      expect(Backup.toPrune(names, keep: 14), [
        'dosekeeper-backup-2026-09-02.json',
        'dosekeeper-backup-2026-09-01.json',
      ]);
    });

    test('prunes nothing while under the limit', () {
      expect(Backup.toPrune(['dosekeeper-backup-2026-09-24.json'], keep: 14), isEmpty);
    });
  });
}
