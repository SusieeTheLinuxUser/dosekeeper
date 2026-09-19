import '../data/database.dart';
import '../models/medication.dart';
import 'alarm_bridge.dart';

/// Turns medication schedules into concrete doses, and arms native alarms for them.
///
/// Doses are materialised into the database rather than computed on the fly so that
/// history, "taken" marks and the activity grid all have something stable to point at.
class DoseScheduler {
  DoseScheduler(this._db);

  final DoseDatabase _db;

  /// How far ahead to materialise doses and arm alarms. Android tolerates a few dozen
  /// pending alarms comfortably; this keeps us well inside that.
  static const horizon = Duration(days: 3);

  /// Regenerates upcoming doses and re-arms alarms. Safe to call repeatedly --
  /// dose creation is idempotent on (medication, scheduled_at).
  Future<void> sync({DateTime? now}) async {
    final start = now ?? DateTime.now();
    final meds = await _db.medications(activeOnly: true);

    await _materialiseDoses(meds, start);
    await _armAlarms(meds, start);
  }

  Future<void> _materialiseDoses(List<Medication> meds, DateTime now) async {
    final today = DateTime(now.year, now.month, now.day);
    for (var dayOffset = 0; dayOffset <= horizon.inDays; dayOffset++) {
      final day = today.add(Duration(days: dayOffset));
      for (final med in meds) {
        if (med.id == null || !med.occursOn(day)) continue;
        for (final minutes in med.timesOfDay) {
          final at = day.add(Duration(minutes: minutes));
          // Don't create doses for times that already passed before the med existed.
          if (at.isBefore(now.subtract(const Duration(hours: 12)))) continue;
          await _db.ensureDose(med.id!, at);
        }
      }
    }
  }

  Future<void> _armAlarms(List<Medication> meds, DateTime now) async {
    final byId = {for (final m in meds) m.id: m};
    final upcoming = await _db.upcomingPendingDoses(now, now.add(horizon));
    for (final dose in upcoming) {
      final med = byId[dose.medicationId];
      if (med == null || dose.id == null) continue;
      await AlarmBridge.scheduleDose(
        doseId: dose.id!,
        triggerAt: dose.scheduledAt,
        medName: med.name,
        dosage: med.dosage,
      );
    }
  }

  /// Applies outcomes the native alarm screen recorded while Dart wasn't running.
  Future<int> applyPendingAlarmActions() async {
    final pending = await AlarmBridge.drainPendingActions();
    for (final action in pending) {
      final dose = await _db.dose(action.doseId);
      if (dose == null) continue;
      if (action.isTaken) {
        await _db.setDoseStatus(action.doseId, DoseStatus.taken, at: action.at);
      }
      // SNOOZE re-arms itself natively; the dose stays pending on purpose.
    }
    return pending.length;
  }

  Future<void> markTaken(int doseId) =>
      _db.setDoseStatus(doseId, DoseStatus.taken);

  Future<void> markSkipped(int doseId) =>
      _db.setDoseStatus(doseId, DoseStatus.skipped);

  /// Cancels alarms for a medication's future doses (e.g. when it's deleted/paused).
  Future<void> cancelFutureAlarmsFor(int medicationId, {DateTime? now}) async {
    final start = now ?? DateTime.now();
    final upcoming = await _db.upcomingPendingDoses(start, start.add(horizon));
    for (final dose in upcoming.where((d) => d.medicationId == medicationId)) {
      if (dose.id != null) await AlarmBridge.cancelDose(dose.id!);
    }
  }
}
