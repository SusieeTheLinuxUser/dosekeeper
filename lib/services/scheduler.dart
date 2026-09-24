import '../data/database.dart';
import '../models/medication.dart';
import 'alarm_bridge.dart';
import 'backup_format.dart';

/// Turns medication schedules into concrete doses, and arms native alarms for them.
///
/// Doses are materialised into the database rather than computed on the fly so that
/// history, "taken" marks and the activity grid all have something stable to point at.
class DoseScheduler {
  final _db = DoseDatabase.instance;

  /// How far ahead to materialise doses and arm alarms. Android tolerates a few dozen
  /// pending alarms comfortably; this keeps us well inside that.
  static const horizon = Duration(days: 3);

  /// Regenerates upcoming doses and re-arms alarms. Safe to call repeatedly --
  /// dose creation is idempotent on (medication, scheduled_at).
  Future<void> sync({DateTime? now}) async {
    final start = now ?? DateTime.now();
    final meds = await _db.medications(activeOnly: true);

    await _materialiseDoses(meds, start);
    await _reconcileOrphanedDoses(start);
    await _armAlarms(meds, start);
    await _applyFiredAlarmEvents();
    await _updateOutstandingNotification(start);
  }

  /// Cancels and deletes future pending doses that no longer match any medication's
  /// *current* schedule -- e.g. a time that was removed from a medication after doses
  /// for it were already materialised. Without this, editing a medication's schedule
  /// down to fewer times/days leaves the old doses (and their real, armed alarms)
  /// behind forever: still pending, no longer visible anywhere in the editor since
  /// they don't belong to any time the medication currently lists, but still ringing
  /// on schedule regardless. Checked against *all* medications, not just active ones,
  /// so a dose isn't wrongly treated as an orphan just because its medication was
  /// fetched in a different query.
  Future<void> _reconcileOrphanedDoses(DateTime now) async {
    final allMeds = {for (final m in await _db.medications()) m.id: m};
    final upcoming = await _db.upcomingPendingDoses(now, now.add(horizon));
    for (final dose in upcoming) {
      final med = allMeds[dose.medicationId];
      if (dose.id == null) continue;
      if (med == null || !med.coversSlot(dose.scheduledAt)) {
        await AlarmBridge.cancelDose(dose.id!);
        await _db.deleteDose(dose.id!);
      }
    }
  }

  /// Records when each alarm actually fired, independent of what the user did about
  /// it. This is what lets a missed dose be attributed correctly afterwards: "the
  /// alarm never rang" (a real bug, worth fixing) versus "it rang and was ignored"
  /// (a human choice, not a bug) -- instead of the two looking identical in history.
  Future<void> _applyFiredAlarmEvents() async {
    final events = await AlarmBridge.drainFiredEvents();
    for (final event in events) {
      await _db.setDoseFiredAt(event.doseId, event.firedAt);
    }
  }

  /// Doses that rang (or should have) and were never acted on shouldn't just vanish
  /// once the alarm stops -- keep an ongoing, undismissable notification up for them
  /// until they're marked taken or skipped.
  Future<void> _updateOutstandingNotification(DateTime now) async {
    final overdue = (await _db.pendingDosesBefore(now))
        .where((d) => d.effectiveStatus(now) == DoseStatus.missed)
        .toList();

    if (overdue.isEmpty) {
      await AlarmBridge.clearOutstandingNotification();
      return;
    }

    final meds = {for (final m in await _db.medications()) m.id: m};
    final names = overdue
        .map((d) => meds[d.medicationId]?.name)
        .whereType<String>()
        .toSet()
        .join(', ');
    await AlarmBridge.updateOutstandingNotification(
      title: overdue.length == 1 ? '1 dose missed' : '${overdue.length} doses missed',
      text: names,
    );
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
  Future<void> applyPendingAlarmActions() async {
    final pending = await AlarmBridge.drainPendingActions();
    for (final action in pending) {
      final dose = await _db.dose(action.doseId);
      if (dose == null) continue;
      if (action.isTaken) {
        await _db.setDoseStatus(action.doseId, DoseStatus.taken, at: action.at);
      }
      // SNOOZE re-arms itself natively; the dose stays pending on purpose.
    }
  }

  /// Replaces every medication and all history with [backup]'s, then re-arms alarms
  /// for the restored schedule.
  ///
  /// Order matters. First, land anything the native side recorded against the
  /// *current* dose ids (alarm-screen taps, fired times) -- after the swap those ids
  /// mean nothing. Then cancel every alarm the current data has armed, including a
  /// snoozed one whose dose time has already passed: left armed, it would ring for a
  /// dose that no longer exists, the same orphaned-alarm bug PR #7 fixed.
  Future<void> restore(Backup backup, {DateTime? now}) async {
    await applyPendingAlarmActions();
    await _applyFiredAlarmEvents();
    for (final dose in await _db.pendingDosesBefore(DateTime(9999))) {
      if (dose.id != null) await AlarmBridge.cancelDose(dose.id!);
    }
    await _db.replaceAll(backup.medications, backup.doses);
    await sync(now: now);
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
