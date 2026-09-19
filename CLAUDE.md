# DoseKeeper — continuation brief

Read this, then `AGENTS.md` and `README.md` before acting.

## What this is and why

A standalone Android medication reminder. Flutter UI + native Kotlin alarm layer.
No hardware, no account, no server, no network permission.

**Background:** this project began as `~/Projects/medicine-doser` — reverse-engineering
a commercial BLE pill dispenser (that work is complete and lives in its own public
repo, `SusieeTheLinuxUser/dosecontrol-re`). The user then discovered the dispenser's
own official app fails to fire alarms, **and they missed a real dose because of it.**
So the plan changed: abandon the hardware, build a reminder app they control.

That origin is the whole design rationale. **A medication reminder that doesn't fire
is worse than none, because the user trusted it.** Reliability is the product, not a
feature. Do not trade it away for elegance or convenience.

## Current state (2026-09-20)

Built, committed locally (**not yet pushed to any remote**), installed on the user's phone.

- `flutter analyze` clean, 5 unit tests passing, debug APK builds and installs.
- **NOTHING HAS BEEN VERIFIED ON HARDWARE YET.** The alarm has never actually rung.
  This is the single most important open item.

### Implemented

- **Native alarm layer** (`android/app/src/main/kotlin/dev/susiee/dosekeeper/`)
  - `AlarmScheduler.kt` — `AlarmManager.setAlarmClock()`. Chosen deliberately: it is the
    only alarm API Android treats as a genuine user alarm clock (Doze-exempt, App
    Standby-exempt, shows in the status bar). Do not "simplify" this to `setExact` or WorkManager.
  - `AlarmService.kt` — foreground service that rings. Plays on the **alarm** audio stream
    (audible on silent/vibrate), raises volume if muted, loops, vibrates, holds a wake lock,
    `START_REDELIVER_INTENT` so it comes back ringing if killed mid-ring.
  - `AlarmActivity.kt` — native full-screen alarm over the lockscreen, turns the screen on.
    Native (not Flutter) on purpose: must appear instantly from a cold process. Back button
    is intentionally a no-op. Writes TAKEN/SNOOZE to SharedPreferences.
  - `AlarmReceiver.kt` / `BootReceiver.kt` — receiver hands straight off to the service
    (~10s limit); boot receiver sets a reschedule flag (incl. OEM quickboot actions).
  - `MainActivity.kt` — MethodChannel `dev.susiee.dosekeeper/alarms`.
- **Dart side** — `models/medication.dart` (Medication, Dose, status logic),
  `data/database.dart` (SQLite), `services/scheduler.dart` (materialises doses 3 days ahead,
  arms alarms, drains native outcomes), `services/alarm_bridge.dart`, and UI
  (`today_page`, `medications_page`, `medication_edit_page`).
- **Self-diagnosis** — Today screen warns if exact alarms are blocked or battery
  optimisation is on, with one-tap links to the system settings that fix it.

### Not implemented yet

1. **Persistent ongoing notification** — user explicitly asked for this: an undismissable
   notification so an outstanding/missed dose can't be swiped away and forgotten.
2. **GitHub-style adherence grid** — user's "silly" idea, genuinely wanted. `DoseDatabase.dailyAdherence()`
   already returns per-day taken/total, so the data layer is ready; only the widget is missing.
3. Dose history screen; editing/pausing a med without deleting it; export.

## Best next move

**Verify a real alarm fires on the physical phone, before anything else.** The phone
(`REDACTED_DEVICE_SERIAL`) is connected via adb and the app is installed. Open the app, grant
both permission warnings, then test: ring in 10s with the screen on, then ring in 60s
with the phone **locked**, then ideally an overnight test. Only after that should
features get added.

Then: persistent notification, then the activity grid.

## Guardrails

- **Reliability over everything.** Never weaken the alarm path (alarm stream, foreground
  service, full-screen intent, `setAlarmClock`) for cleanliness or battery friendliness.
- **Don't let the user rely on this until it's proven.** They have already missed a dose
  trusting software. Until alarms are verified over several real days, say plainly that
  they should keep a backup reminder.
- **Test on the real device**, not just an emulator — OEM battery-killing is the entire
  problem class here. User's phone is OnePlus/Oppo **ColorOS** (`CPH2747`), one of the
  worst offenders (see dontkillmyapp.com).
- It's a health-adjacent app but **not a medical device** — no dosing advice, no claims
  of clinical reliability.
- Open source, MIT. Keep it free and account-free.

## Environment

- Flutter 3.47.4, Dart 3.13.3 at `/home/susiee/development/flutter/bin/flutter`
- Android SDK at `~/Android/Sdk` (platforms 34/35/36), Java 26, `adb` on PATH
- No Android Studio — build via `flutter build apk --debug` / `flutter install`
- `flutter test` and `flutter analyze` both work

## Conventions

- Update this file and `AGENTS.md` after any meaningful chunk of work — the user moves
  between Claude, ChatGPT/Codex, Qwen, Kimi and Z.ai, and these files are the only handoff.
- Non-trivial logic gets a test (`test/widget_test.dart` covers the scheduling maths).
- Keep the native alarm layer commented with *why*, not what — the "why" is what stops
  a future contributor refactoring the reliability out of it.
