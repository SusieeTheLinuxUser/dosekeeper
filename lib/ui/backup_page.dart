import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/medication.dart';
import '../services/backup_bridge.dart';
import '../services/backup_format.dart';
import '../services/backup_service.dart';
import '../services/scheduler.dart';

/// Choose the backup folder, back up now, or restore from a backup file.
class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.scheduler});
  final DoseScheduler scheduler;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final _service = BackupService.instance;
  BackupFolderStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final status = await BackupBridge.status();
    if (mounted) setState(() => _status = status);
  }

  /// Runs [work] with the buttons disabled, reporting any failure instead of
  /// swallowing it.
  Future<void> _run(Future<void> Function() work) async {
    setState(() => _busy = true);
    try {
      await work();
    } on PlatformException catch (e) {
      _toast('Failed: ${e.message ?? e.code}');
    } on FormatException catch (e) {
      _toast(e.message);
    } finally {
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _chooseFolder() => _run(() async {
        final picked = await BackupBridge.pickFolder();
        if (picked == null) return; // backed out

        // Picking a folder that already holds backups is what someone does after a
        // reinstall. Offer the restore *before* the first automatic backup can
        // overwrite today's file with whatever is on the phone now.
        final existing = Backup.newestFirst(await BackupBridge.list());
        if (existing.isNotEmpty && mounted) {
          final restore = await _askRestoreFromFolder(existing.first);
          if (restore == true) {
            await _restore(Backup.decode(await BackupBridge.read(existing.first)));
            return;
          }
        }
        await _service.backUp();
        _toast('Backups will be saved to ${picked.folderName}');
      });

  Future<bool?> _askRestoreFromFolder(String newest) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('This folder has backups'),
          content: Text(
            'The newest is from ${Backup.dayOf(newest)}.\n\n'
            'Restore it? Or keep what is on this phone now, and back that up from '
            'here on (this replaces today\'s backup file, if there is one).',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep this phone\'s data'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );

  Future<void> _backUpNow() => _run(() async {
        final before = await _service.snapshot();
        if (before.isEmpty) {
          _toast('Nothing to back up yet');
          return;
        }
        await _service.backUp();
        _toast('Backed up');
      });

  Future<void> _restoreFromFile() => _run(() async {
        final raw = await BackupBridge.pickFile();
        if (raw == null) return; // backed out
        await _restore(Backup.decode(raw));
      });

  /// Confirms, then replaces everything. Always confirmed: a restore overwrites every
  /// medication and all history currently on the phone.
  Future<void> _restore(Backup backup) async {
    final taken = backup.doses.where((d) => d.status == DoseStatus.taken).length;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace everything with this backup?'),
        content: Text(
          'Backup from ${DateFormat('d MMM yyyy, HH:mm').format(backup.exportedAt)}:\n'
          '${backup.medications.length} medication(s), '
          '${backup.doses.length} dose record(s), $taken taken.\n\n'
          'All medications and history currently on this phone will be replaced.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.scheduler.restore(backup);
    await _service.backUpQuietly();
    _toast('Restored ${backup.medications.length} medication(s). Alarms re-armed.');
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final last = status?.lastBackupAt;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: status == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: Icon(
                      status.enabled ? Icons.cloud_done_outlined : Icons.cloud_off,
                      color: status.enabled ? const Color(0xFF6EE7A8) : Colors.orange,
                    ),
                    title: Text(status.enabled
                        ? 'Backing up to "${status.folderName}"'
                        : 'Backups are off'),
                    subtitle: Text(last == null
                        ? 'No backup yet'
                        : 'Last backup ${DateFormat('d MMM, HH:mm').format(last)}'),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _chooseFolder,
                  icon: const Icon(Icons.folder_open),
                  label: Text(status.enabled ? 'Change folder' : 'Choose backup folder'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy || !status.enabled ? null : _backUpNow,
                  icon: const Icon(Icons.backup_outlined),
                  label: const Text('Back up now'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _restoreFromFile,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore from a backup file'),
                ),
                const SizedBox(height: 24),
                Text(
                  'DoseKeeper saves one backup file per day in the folder you choose, '
                  'updated every time the app opens or you change something. The last '
                  '${BackupService.keepDays} days are kept.\n\n'
                  'Pick a folder like Documents, not one inside the app: it survives '
                  'uninstalling DoseKeeper, and you can copy it to a computer. After a '
                  'reinstall, choose the same folder again to restore.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
