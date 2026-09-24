import 'package:flutter/services.dart';

/// Thin wrapper over the native backup-folder layer (see android/.../BackupStore.kt).
/// Shares the alarm channel: one channel, one MainActivity handler.
class BackupBridge {
  static const _channel = MethodChannel('dev.susiee.dosekeeper/alarms');

  static Future<BackupFolderStatus> status() async => BackupFolderStatus.fromMap(
        await _channel.invokeMapMethod<String, Object?>('backupStatus') ?? const {},
      );

  /// Opens the system folder picker. Null if the user backed out.
  static Future<BackupFolderStatus?> pickFolder() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('pickBackupFolder');
    return raw == null ? null : BackupFolderStatus.fromMap(raw);
  }

  static Future<List<String>> list() async =>
      await _channel.invokeListMethod<String>('listBackups') ?? const [];

  static Future<String> read(String name) async =>
      (await _channel.invokeMethod<String>('readBackup', {'name': name}))!;

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
