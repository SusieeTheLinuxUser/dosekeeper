import 'package:flutter/services.dart';

import '../data/database.dart';
import 'backup_bridge.dart';
import 'backup_format.dart';

/// Automatic daily backups to a folder the user picked.
///
/// Runs whenever the Today screen refreshes -- app open, resume, and after every
/// change -- rather than on a background timer. That is enough to never miss data:
/// the database only ever changes while the app's Dart side is running (alarm-screen
/// taps wait natively until the next open, and are drained into the database before
/// this runs), so a backup taken at each of those moments is always current. Each run
/// rewrites that day's file, so there is one file per day and earlier days' files are
/// untouched snapshots.
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  /// Daily files kept; older ones are deleted. Two weeks of history to fall back on.
  static const keepDays = 14;

  final _db = DoseDatabase.instance;

  /// Why the last automatic backup failed, or null if it worked (or hasn't run).
  /// Shown on the Today screen: a backup that quietly stopped working is worse than
  /// none, for the same reason an alarm that quietly doesn't ring is.
  String? lastError;

  Future<Backup> snapshot({DateTime? now}) async => Backup(
        exportedAt: now ?? DateTime.now(),
        medications: await _db.medications(),
        doses: await _db.allDoses(),
      );

  /// Writes today's backup file and prunes old ones. Returns the folder status
  /// afterwards; does nothing if no folder is chosen.
  ///
  /// Never writes an empty database: right after a reinstall the app is empty, and
  /// pointing it back at the old backup folder must not overwrite today's real backup
  /// with nothing before the user has had the chance to restore it.
  Future<BackupFolderStatus> backUp({DateTime? now}) {
    // One at a time: the Today screen and the backup page can both trigger one, and
    // two concurrent writes to the same file could interleave into a corrupt backup.
    final run = _running.then((_) => _backUp(now: now));
    _running = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _running = Future.value();

  Future<BackupFolderStatus> _backUp({DateTime? now}) async {
    final status = await BackupBridge.status();
    if (!status.enabled) return status;

    final at = now ?? DateTime.now();
    final snap = await snapshot(now: at);
    if (snap.isEmpty) return status;

    try {
      await BackupBridge.write(Backup.fileNameFor(at), snap.encode());
      lastError = null;
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      rethrow;
    }

    // Pruning is housekeeping: if it fails, today's backup still exists.
    try {
      for (final name in Backup.toPrune(await BackupBridge.list(), keep: keepDays)) {
        await BackupBridge.delete(name);
      }
    } on PlatformException {
      // Leaves an extra old file behind; harmless.
    }
    return BackupBridge.status();
  }

  /// [backUp] for the automatic path: failures are recorded in [lastError] for the
  /// Today screen instead of thrown, so a broken backup never breaks the alarms'
  /// refresh.
  Future<BackupFolderStatus?> backUpQuietly() async {
    try {
      return await backUp();
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      return null;
    }
  }
}
