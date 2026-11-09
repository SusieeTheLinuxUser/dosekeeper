import 'package:flutter/services.dart';

/// Thin wrapper over the native alarm layer (see android/.../AlarmScheduler.kt).
class AlarmBridge {
  static const _channel = MethodChannel('dev.susiee.dosekeeper/alarms');

  /// False if Android refused the alarm (e.g. its per-app alarm limit): it won't ring.
  static Future<bool> scheduleDose({
    required int doseId,
    required DateTime triggerAt,
    required String medName,
    required String dosage,
  }) async =>
      await _channel.invokeMethod<bool>('scheduleDose', {
        'doseId': doseId,
        'triggerAt': triggerAt.millisecondsSinceEpoch,
        'medName': medName,
        'dosage': dosage,
      }) ??
      false;

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

  /// Android 14+: the lockscreen takeover also needs this switch on. Always true below 14.
  static Future<bool> canUseFullScreenIntent() async =>
      await _channel.invokeMethod<bool>('canUseFullScreenIntent') ?? true;

  static Future<void> openFullScreenIntentSettings() =>
      _channel.invokeMethod('openFullScreenIntentSettings');

  /// Notification for doses past their grace period, as of [shownAt]. Stays until
  /// [clearOutstandingNotification] is called or the user swipes it away, which
  /// discards those doses for good: see [outstandingDismissedThrough].
  /// [doseId] is set only when it covers exactly one dose, which gives it Taken/Skip
  /// action buttons; with several doses the tap just opens the app.
  static Future<void> updateOutstandingNotification({
    required String title,
    required String text,
    required DateTime shownAt,
    int? doseId,
  }) =>
      _channel.invokeMethod('updateOutstandingNotification', {
        'title': title,
        'text': text,
        'shownAt': shownAt.millisecondsSinceEpoch,
        'doseId': ?doseId,
      });

  /// The [updateOutstandingNotification] `shownAt` of the last notification the user
  /// swiped away. Epoch if they never have.
  static Future<DateTime> outstandingDismissedThrough() async =>
      DateTime.fromMillisecondsSinceEpoch(
        await _channel.invokeMethod<int>('outstandingDismissedThrough') ?? 0,
      );

  static Future<void> clearOutstandingNotification() =>
      _channel.invokeMethod('clearOutstandingNotification');

  /// Tells the native side a headless backgroundSync run is over, so it can tear the
  /// engine down. Only the backgroundSync entry point calls this; the foreground app
  /// never does.
  static Future<void> backgroundSyncDone() =>
      _channel.invokeMethod('backgroundSyncDone');

  /// The installed version as Android reports it, e.g. "1.1.0" or "1.1.0-debug".
  static Future<String> appVersion() async =>
      await _channel.invokeMethod<String>('appVersion') ?? 'Unknown';

  /// Snooze length in minutes. Stored natively because the native alarm screen
  /// snoozes while Dart may not be running; unknown values fall back to 10 there.
  static Future<int> getSnoozeMinutes() async =>
      await _channel.invokeMethod<int>('getSnoozeMinutes') ?? 10;

  /// The lengths the user can pick; must match SnoozePrefs.ALLOWED natively.
  static const snoozeChoices = [5, 10, 15, 30];

  /// Sets the snooze length in minutes. Anything outside [snoozeChoices] is
  /// ignored natively and leaves the previous value alone.
  static Future<void> setSnoozeMinutes(int minutes) =>
      _channel.invokeMethod('setSnoozeMinutes', {'minutes': minutes});

  /// Whether the alarm starts quiet and steps up to full volume over 30 seconds.
  /// Stored natively because AlarmService rings while Dart may not be running.
  /// Default off: an alarm stays full volume unless the user chooses otherwise.
  static Future<bool> getVolumeRamp() async =>
      await _channel.invokeMethod<bool>('getVolumeRamp') ?? false;

  static Future<void> setVolumeRamp(bool enabled) =>
      _channel.invokeMethod('setVolumeRamp', {'enabled': enabled});

  /// Opens [url] in the browser. The app itself still makes no network requests.
  /// False if nothing on the phone can open it.
  static Future<bool> openUrl(String url) async =>
      await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;

  /// Fires a real alarm N seconds out, through the exact same pipeline as a real
  /// dose, to prove end-to-end that it rings on this device.
  static Future<void> testAlarm(int seconds) =>
      _channel.invokeMethod('testAlarm', {'seconds': seconds});

  /// Outcomes the native alarm screen (or a missed-notification Taken/Skip button)
  /// recorded while Dart was not running.
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
  final String action; // TAKEN | SKIPPED | SNOOZE
  final DateTime at;

  bool get isTaken => action == 'TAKEN';
  bool get isSkipped => action == 'SKIPPED';

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
