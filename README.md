# DoseKeeper

A medication reminder for Android that actually rings.

Built after a commercial Bluetooth pill dispenser and its companion app silently
failed to fire an alarm, causing a missed dose. This app deliberately owns nothing
but your phone: no hardware, no account, no server, no network permission at all.

## Why it's built this way

A medication reminder that doesn't fire is worse than no reminder, because you
trusted it. Everything here is shaped around that:

- **`AlarmManager.setAlarmClock()`**, not `setExact` or a work queue. It's the only
  alarm API Android treats as a real user-facing alarm clock: exempt from Doze,
  unaffected by App Standby buckets, and visible in the status bar.
- **A foreground service does the ringing**, so a killed activity can't silence it,
  and it plays on the alarm audio stream so it's audible on silent/vibrate.
- **A full-screen intent** takes over the lockscreen and turns the screen on. A
  heads-up notification you can sleep through isn't good enough.
- **The alarm screen is native**, not Flutter, so it can appear instantly from a
  cold process without waiting for a Dart engine to start.
- **The app surfaces its own failure modes.** If exact alarms are blocked or battery
  optimisation is enabled, the Today screen warns you and links straight to the fix.

### Aggressive OEM battery managers

Some Android skins (ColorOS/OxygenOS, MIUI, One UI, and others) kill background apps
well beyond stock Android's rules, and are a common cause of missed alarms. After
installing, allow the app to run in the background and disable battery optimisation
for it. The Today screen flags both if they're not set.

See [dontkillmyapp.com](https://dontkillmyapp.com) for per-manufacturer steps.

## Features

- Add medications with multiple times per day and per-weekday schedules
- Full-screen ringing alarm with **Taken** / **Snooze 10 min**
- Doses marked taken/skipped, with missed doses detected after a grace period
- Everything stored locally in SQLite

- Persistent, undismissable notification for any dose still outstanding past its
  grace period, so it can't be swiped away and forgotten
- A GitHub-style adherence grid on the Today screen

Planned: a dose history view, editing/pausing a medication without deleting it, export.

## Building

```bash
flutter pub get
flutter build apk --debug
flutter install --debug
```

Always pass `--debug`. Plain `flutter install` installs the release build, and it
uninstalls the existing app first. That deletes all your medications and dose history,
and cancels every alarm.

Requires the Android SDK and Flutter 3.x.

## Status

Early. A test alarm has rung once on real hardware, screen-on and locked, and it worked.
That's one data point, not proof — **verify it on your own device before relying on it**,
including at least one overnight test, before you drop your existing reminders.

## Licence

[MIT](https://github.com/SusieeTheLinuxUser/dosekeeper?tab=MIT-1-ov-file)
