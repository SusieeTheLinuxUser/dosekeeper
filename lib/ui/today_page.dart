import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../models/medication.dart';
import '../services/alarm_bridge.dart';
import '../services/scheduler.dart';
import 'adherence_grid.dart';

class TodayPage extends StatefulWidget {
  const TodayPage({super.key, required this.scheduler});
  final DoseScheduler scheduler;

  @override
  State<TodayPage> createState() => TodayPageState();
}

class TodayPageState extends State<TodayPage> {
  final _db = DoseDatabase.instance;
  List<({Dose dose, Medication med})> _items = [];
  bool _loading = true;
  bool _exactOk = true;
  bool _batteryOk = true;
  bool _notificationsOk = true;
  Map<DateTime, ({int taken, int total})> _adherence = {};

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    await widget.scheduler.applyPendingAlarmActions();
    await widget.scheduler.sync();

    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final doses = await _db.dosesBetween(start, start.add(const Duration(days: 1)));
    final meds = {for (final m in await _db.medications()) m.id: m};

    final exact = await AlarmBridge.canScheduleExact();
    final battery = await AlarmBridge.isIgnoringBatteryOptimizations();
    final notifications = await AlarmBridge.hasNotificationPermission();
    final adherence = await _db.dailyAdherence(
      start.subtract(const Duration(days: 26 * 7)),
      start.add(const Duration(days: 1)),
    );

    if (!mounted) return;
    setState(() {
      _items = [
        for (final d in doses)
          if (meds[d.medicationId] != null)
            (dose: d, med: meds[d.medicationId]!),
      ];
      _exactOk = exact;
      _batteryOk = battery;
      _notificationsOk = notifications;
      _adherence = adherence;
      _loading = false;
    });
  }

  Future<void> _setStatus(Dose dose, DoseStatus status) async {
    if (dose.id == null) return;
    status == DoseStatus.taken
        ? await widget.scheduler.markTaken(dose.id!)
        : await widget.scheduler.markSkipped(dose.id!);
    await AlarmBridge.cancelDose(dose.id!);
    await refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final now = DateTime.now();
    final warnings = <Widget>[
      if (!_notificationsOk)
        _Warning(
          text: 'Notifications are off. The alarm will ring but won\'t take '
              'over the lockscreen.',
          actionLabel: 'Fix',
          onAction: () async {
            await AlarmBridge.requestNotificationPermission();
            await Future<void>.delayed(const Duration(seconds: 1));
            await refresh();
          },
        ),
      if (!_exactOk)
        _Warning(
          text: 'Exact alarms are blocked. Alarms may not ring on time.',
          actionLabel: 'Fix',
          onAction: () async {
            await AlarmBridge.openExactAlarmSettings();
            await Future<void>.delayed(const Duration(seconds: 1));
            await refresh();
          },
        ),
      if (!_batteryOk)
        _Warning(
          text: 'Battery optimisation is on. Android may kill alarms.',
          actionLabel: 'Fix',
          onAction: () async {
            await AlarmBridge.requestIgnoreBatteryOptimizations();
            await Future<void>.delayed(const Duration(seconds: 1));
            await refresh();
          },
        ),
    ];

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          ...warnings,
          if (warnings.isNotEmpty) const SizedBox(height: 8),
          Text(
            DateFormat('EEEE, d MMMM').format(now),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          AdherenceGrid(data: _adherence, today: DateTime(now.year, now.month, now.day)),
          const SizedBox(height: 20),
          if (_items.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: Center(
                child: Text(
                  'Nothing scheduled today.\nAdd a medication to get started.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          for (final item in _items)
            _DoseTile(
              dose: item.dose,
              med: item.med,
              now: now,
              onTaken: () => _setStatus(item.dose, DoseStatus.taken),
              onSkip: () => _setStatus(item.dose, DoseStatus.skipped),
            ),
        ],
      ),
    );
  }
}

class _DoseTile extends StatelessWidget {
  const _DoseTile({
    required this.dose,
    required this.med,
    required this.now,
    required this.onTaken,
    required this.onSkip,
  });

  final Dose dose;
  final Medication med;
  final DateTime now;
  final VoidCallback onTaken;
  final VoidCallback onSkip;

  /// For a missed dose, distinguishes "the alarm never rang" (a real bug -- the OS
  /// never even delivered the broadcast) from "it rang and was ignored" (a human
  /// choice). Without firedAt these look identical, which is exactly the ambiguity
  /// that made it impossible to tell what happened the first time a dose was missed.
  static String _subtitle(DoseStatus status, String time, DateTime? firedAt) {
    if (status != DoseStatus.missed) return time;
    return firedAt == null ? '$time · missed (alarm may not have rung)' : '$time · missed';
  }

  @override
  Widget build(BuildContext context) {
    final status = dose.effectiveStatus(now);
    final time = DateFormat('HH:mm').format(dose.scheduledAt);

    final (Color color, IconData icon) = switch (status) {
      DoseStatus.taken => (const Color(0xFF6EE7A8), Icons.check_circle),
      DoseStatus.skipped => (Colors.grey, Icons.remove_circle_outline),
      DoseStatus.missed => (Colors.redAccent, Icons.error),
      DoseStatus.pending => (Colors.blueGrey, Icons.schedule),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon, color: color, size: 30),
        title: Text(
          med.dosage.isEmpty ? med.name : '${med.name}  ·  ${med.dosage}',
          style: TextStyle(
            decoration:
                status == DoseStatus.skipped ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Text(
          _subtitle(status, time, dose.firedAt),
          style: TextStyle(color: status == DoseStatus.missed ? color : null),
        ),
        trailing: status == DoseStatus.taken || status == DoseStatus.skipped
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Skip',
                    onPressed: onSkip,
                    icon: const Icon(Icons.close),
                  ),
                  FilledButton(onPressed: onTaken, child: const Text('Taken')),
                ],
              ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Card(
        color: Colors.orange.withValues(alpha: 0.15),
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const Icon(Icons.warning_amber, color: Colors.orange),
          title: Text(text, style: const TextStyle(fontSize: 13)),
          trailing: TextButton(onPressed: onAction, child: Text(actionLabel)),
        ),
      );
}
