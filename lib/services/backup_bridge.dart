import 'package:flutter/services.dart';

/// Thin wrapper over the native backup-folder layer (see android/.../BackupStore.kt).
/// Shares the alarm channel: one channel, one MainActivity handler.
class BackupBridge {
  static const _channel = MethodChannel('dev.susiee.dosekeeper/alarms');

  static Future<BackupFolderStatus> status() async => BackupFolderStatus.fromMap(
        await _channel.invokeMapMethod<String, Object?>('backupStatus') ?? const {},
      );

  /// Opens the system folder picker. The picked folder is *pending*, not active: it
  /// only becomes the backup folder via [confirmFolder]. Returns the pending folder's
  /// name, or null if the user backed out.
  static Future<String?> pickFolder() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('pickBackupFolder');
    return raw?['folderName'] as String?;
  }

  /// Makes the pending folder the backup folder.
  static Future<void> confirmFolder() => _channel.invokeMethod('confirmBackupFolder');

  /// Drops the pending folder without making it active; releases its grant.
  static Future<void> discardFolder() => _channel.invokeMethod('discardBackupFolder');

  /// Whether Android's Google backup may copy app data. Off unless the user turns it on.
  static Future<bool> googleBackupEnabled() async =>
      await _channel.invokeMethod<bool>('googleBackupEnabled') ?? false;

  static Future<void> setGoogleBackupEnabled(bool enabled) =>
      _channel.invokeMethod('setGoogleBackupEnabled', {'enabled': enabled});

  /// Lists the backup folder, or the pending one with [pending] (a folder just picked
  /// that has not been confirmed yet).
  static Future<List<String>> list({bool pending = false}) async =>
      await _channel.invokeListMethod<String>('listBackups', {'pending': pending}) ??
      const [];

  static Future<String> read(String name, {bool pending = false}) async =>
      (await _channel.invokeMethod<String>('readBackup', {'name': name, 'pending': pending}))!;

  static Future<void> write(String name, String content) =>
      _channel.invokeMethod('writeBackup', {'name': name, 'content': content});

  static Future<void> delete(String name) =>
      _channel.invokeMethod('deleteBackup', {'name': name});

  /// Opens the system file picker and returns the chosen file's text, or null if the
  /// user backed out.
  static Future<String?> pickFile() => _channel.invokeMethod<String>('pickBackupFile');
}

class BackupFolderStatus {
  const BackupFolderStatus({this.folderName, this.lastBackupAt});

  /// Null when no folder is chosen, or its permission is gone -- backups are off.
  final String? folderName;
  final DateTime? lastBackupAt;

  bool get enabled => folderName != null;

  static BackupFolderStatus fromMap(Map<String, Object?> m) => BackupFolderStatus(
        folderName: m['folderName'] as String?,
        lastBackupAt: m['lastBackupAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((m['lastBackupAt'] as num).toInt()),
      );
}
