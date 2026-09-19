import 'package:flutter/material.dart';

import '../data/database.dart';
import '../models/medication.dart';

class MedicationEditPage extends StatefulWidget {
  const MedicationEditPage({super.key, this.existing});
  final Medication? existing;

  @override
  State<MedicationEditPage> createState() => _MedicationEditPageState();
}

class _MedicationEditPageState extends State<MedicationEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _dosage =
      TextEditingController(text: widget.existing?.dosage ?? '');
  late List<int> _times = [...?widget.existing?.timesOfDay];
  late Set<int> _days = {...?widget.existing?.daysOfWeek} .isEmpty
      ? {...Medication.everyDay}
      : {...widget.existing!.daysOfWeek};

  @override
  void dispose() {
    _name.dispose();
    _dosage.dispose();
    super.dispose();
  }

  Future<void> _addTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );
    if (picked == null) return;
    final minutes = picked.hour * 60 + picked.minute;
    if (!_times.contains(minutes)) {
      setState(() => _times = [..._times, minutes]..sort());
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_times.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one time of day')),
      );
      return;
    }
    if (_days.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick at least one day')),
      );
      return;
    }

    final med = (widget.existing ??
            Medication(name: '', timesOfDay: const [], daysOfWeek: const {}))
        .copyWith(
      name: _name.text.trim(),
      dosage: _dosage.text.trim(),
      timesOfDay: _times,
      daysOfWeek: _days,
    );
    await DoseDatabase.instance.upsertMedication(med);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    const dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Add medication' : 'Edit medication'),
        actions: [
          IconButton(onPressed: _save, icon: const Icon(Icons.check)),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _name,
              autofocus: widget.existing == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Sertraline',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Give it a name' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _dosage,
              decoration: const InputDecoration(
                labelText: 'Dose (optional)',
                hintText: 'e.g. 50mg, 2 tablets',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 28),
            Text('Times of day', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in _times)
                  InputChip(
                    label: Text(Medication.formatTime(m)),
                    onDeleted: () => setState(() => _times = [..._times]..remove(m)),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Add time'),
                  onPressed: _addTime,
                ),
              ],
            ),
            const SizedBox(height: 28),
            Text('Days', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var d = 1; d <= 7; d++)
                  ChoiceChip(
                    label: Text(dayLabels[d - 1]),
                    selected: _days.contains(d),
                    onSelected: (sel) => setState(() {
                      sel ? _days.add(d) : _days.remove(d);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => _days = {...Medication.everyDay}),
              child: const Text('Every day'),
            ),
          ],
        ),
      ),
    );
  }
}
