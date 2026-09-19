import 'package:flutter/material.dart';

import '../data/database.dart';
import '../models/medication.dart';
import '../services/scheduler.dart';
import 'medication_edit_page.dart';

class MedicationsPage extends StatefulWidget {
  const MedicationsPage({super.key, required this.scheduler, this.onChanged});
  final DoseScheduler scheduler;
  final VoidCallback? onChanged;

  @override
  State<MedicationsPage> createState() => MedicationsPageState();
}

class MedicationsPageState extends State<MedicationsPage> {
  List<Medication> _meds = [];

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final meds = await DoseDatabase.instance.medications();
    if (!mounted) return;
    setState(() => _meds = meds);
  }

  Future<void> _openEditor([Medication? existing]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => MedicationEditPage(existing: existing)),
    );
    if (saved == true) {
      await widget.scheduler.sync();
      await refresh();
      widget.onChanged?.call();
    }
  }

  Future<void> _delete(Medication med) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${med.name}?'),
        content: const Text(
          'Its upcoming alarms will be cancelled. Past history is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || med.id == null) return;

    await widget.scheduler.cancelFutureAlarmsFor(med.id!);
    await DoseDatabase.instance.deleteMedication(med.id!);
    await refresh();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _meds.isEmpty
          ? const Center(child: Text('No medications yet'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _meds.length,
              itemBuilder: (_, i) {
                final med = _meds[i];
                return Card(
                  child: ListTile(
                    title: Text(med.dosage.isEmpty
                        ? med.name
                        : '${med.name}  ·  ${med.dosage}'),
                    subtitle: Text(_describe(med)),
                    onTap: () => _openEditor(med),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(med),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
    );
  }

  static String _describe(Medication med) {
    final times = med.timesOfDay.map(Medication.formatTime).join(', ');
    final everyDay = med.daysOfWeek.length == 7;
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final days = everyDay
        ? 'every day'
        : (med.daysOfWeek.toList()..sort()).map((d) => names[d - 1]).join(', ');
    return '$times  ·  $days';
  }
}
