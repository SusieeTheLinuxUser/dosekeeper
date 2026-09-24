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

  /// True when the battery is at or below 20% and not plugged in. A phone that
  /// powers off overnight can't ring, which no amount of alarm-pipeline hardening
  /// can fix -- the only defence is telling the user to charge while there's time.
  static Future<bool> isBatteryLow() async =>
      await _channel.invokeMethod<bool>('isBatteryLow') ?? false;

  static Future<void> openBatterySettings() =>
      _channel.invokeMethod('openBatterySettings');

  /// Without this, the alarm's full-screen lockscreen takeover silently never fires
  /// (the OS drops the notification it rides on) even though the alarm still rings.
  static Future<bool> hasNotificationPermission() async =>
      await _channel.invokeMethod<bool>('hasNotificationPermission') ?? false;

  static Future<void> requestNotificationPermission() =>
      _channel.invokeMethod('requestNotificationPermission');

  /// Ongoing, undismissable notification for doses past their grace period. Stays
  /// until [clearOutstandingNotification] is called, so it can't be swiped away and
  /// forgotten the way a normal notification could.
  static Future<void> updateOutstandingNotification({
    required String title,
    required String text,
  }) =>
      _channel.invokeMethod('updateOutstandingNotification', {
        'title': title,
        'text': text,
      });

  static Future<void> clearOutstandingNotification() =>
      _channel.invokeMethod('clearOutstandingNotification');

  static Future<bool> consumeNeedsReschedule() async =>
      await _channel.invokeMethod<bool>('consumeNeedsReschedule') ?? false;

  /// Fires a real alarm N seconds out, through the exact same pipeline as a real
  /// dose, to prove end-to-end that it rings on this device.
  static Future<void> testAlarm(int seconds) =>
      _channel.invokeMethod('testAlarm', {'seconds': seconds});

  /// Outcomes the native alarm screen recorded while Dart was not running.
  static Future<List<PendingAlarmAction>> drainPendingActions() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('drainPendingActions');
    return (raw ?? [])
        .map((e) => PendingAlarmAction.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// When each alarm actually fired (recorded by AlarmReceiver the instant the OS
  /// delivers it), independent of whether/how the user responded. This is what makes
  /// a missed dose attributable: "the alarm never rang" versus "it rang and was
  /// ignored" are very different findings, and without this there's no way to tell
  /// them apart after the fact.
  static Future<List<FiredAlarmEvent>> drainFiredEvents() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('drainFiredEvents');
    return (raw ?? [])
        .map((e) => FiredAlarmEvent.fromMap(Map<String, dynamic>.from(e as Map)))
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

class FiredAlarmEvent {
  const FiredAlarmEvent({required this.doseId, required this.firedAt});

  final int doseId;
  final DateTime firedAt;

  static FiredAlarmEvent fromMap(Map<String, dynamic> m) => FiredAlarmEvent(
        doseId: (m['doseId'] as num).toInt(),
        firedAt: DateTime.fromMillisecondsSinceEpoch((m['firedAt'] as num).toInt()),
      );
}
