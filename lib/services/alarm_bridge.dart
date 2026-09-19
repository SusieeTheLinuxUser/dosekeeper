import 'package:flutter/services.dart';

/// Thin wrapper over the native alarm layer (see android/.../AlarmScheduler.kt).
class AlarmBridge {
  static const _channel = MethodChannel('dev.susiee.dosekeeper/alarms');

  static Future<void> scheduleDose({
    required int doseId,
    required DateTime triggerAt,
    required String medName,
    required String dosage,
  }) =>
      _channel.invokeMethod('scheduleDose', {
        'doseId': doseId,
        'triggerAt': triggerAt.millisecondsSinceEpoch,
        'medName': medName,
        'dosage': dosage,
      });

  static Future<void> cancelDose(int doseId) =>
      _channel.invokeMethod('cancelDose', {'doseId': doseId});

  static Future<bool> canScheduleExact() async =>
      await _channel.invokeMethod<bool>('canScheduleExact') ?? false;

  static Future<void> openExactAlarmSettings() =>
      _channel.invokeMethod('openExactAlarmSettings');

  static Future<bool> isIgnoringBatteryOptimizations() async =>
      await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;

  static Future<void> requestIgnoreBatteryOptimizations() =>
      _channel.invokeMethod('requestIgnoreBatteryOptimizations');

  static Future<bool> consumeNeedsReschedule() async =>
      await _channel.invokeMethod<bool>('consumeNeedsReschedule') ?? false;

  /// Outcomes the native alarm screen recorded while Dart was not running.
  static Future<List<PendingAlarmAction>> drainPendingActions() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('drainPendingActions');
    return (raw ?? [])
        .map((e) => PendingAlarmAction.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}

class PendingAlarmAction {
  const PendingAlarmAction({
    required this.doseId,
    required this.action,
    required this.at,
  });

  final int doseId;
  final String action; // TAKEN | SNOOZE
  final DateTime at;

  bool get isTaken => action == 'TAKEN';

  static PendingAlarmAction fromMap(Map<String, dynamic> m) => PendingAlarmAction(
        doseId: (m['doseId'] as num).toInt(),
        action: m['action'] as String? ?? 'TAKEN',
        at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num?)?.toInt() ?? 0),
      );
}
