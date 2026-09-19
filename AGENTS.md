# DoseKeeper — agent instructions

## Purpose

Android medication reminder that reliably rings. Flutter UI, native Kotlin alarm layer.
Local-only: no hardware, no account, no server, no network permission.

Built because a commercial BLE pill dispenser's official app silently failed to fire an
alarm and the user **missed a real dose**. Predecessor project (reverse-engineering that
dispenser) is complete and lives at `~/Projects/medicine-doser` / GitHub
`SusieeTheLinuxUser/dosecontrol-re` — not needed for this work.

## Read first

1. `CLAUDE.md` — current state, what's done, what's next
2. `README.md` — the design rationale, written for users/contributors
3. `android/app/src/main/kotlin/dev/susiee/dosekeeper/AlarmScheduler.kt` — the load-bearing part

## The one rule

**A medication reminder that doesn't fire is worse than none, because the user trusted it.**

Every architectural choice follows from that. When in doubt, choose the option that is
more likely to ring, even if it's uglier. Specifically, do not:

- swap `AlarmManager.setAlarmClock()` for `setExact*`, WorkManager, or a Flutter plugin
- move the ringing out of a foreground service
- drop the full-screen intent in favour of a normal/heads-up notification
- rewrite `AlarmActivity` in Flutter (it must launch from a cold process instantly)
- play audio on anything but the alarm stream

Each of those exists to survive Doze, App Standby, and OEM battery managers.

## Current status

- Implemented: native alarm pipeline, med CRUD (multi-time, per-weekday), today's doses,
  taken/skipped/missed, SQLite persistence, permission self-diagnosis on the Today screen
  (exact alarm, battery optimisation, notification permission), debug test-alarm button,
  persistent ongoing "missed dose" notification (undismissable, clears on taken/skipped),
  GitHub-style adherence grid on the Today screen.
- Passing: `flutter analyze` clean, 8 unit tests, debug APK builds, installed on the phone.
- **Verified once on hardware (2026-09-19):** screen-on and locked-screen full-screen-alarm
  tests both passed manually. **Still unverified: an overnight test.** Top priority — see
  `CLAUDE.md` "Best next move".
- Not built yet: dose history screen; editing/pausing a med without deleting it; export.

## Safety and honesty

- Do not imply the app is proven until alarms have been verified over several real days.
  Tell the user plainly to keep a backup reminder until then.
- Health-adjacent, **not a medical device**: no dosing advice, no clinical claims.
- Test on the real phone (OnePlus/Oppo ColorOS `CPH2747`), not just an emulator —
  OEM process-killing is the entire problem class. See dontkillmyapp.com.

## Working conventions

- Repo is local-only so far (`git log` has the initial commit); **not pushed to a remote yet**.
  Ask before creating/pushing to a public remote.
- Update `CLAUDE.md` and this file after any meaningful chunk of work — the user switches
  between Claude, ChatGPT/Codex, Qwen, Kimi and Z.ai, and these files are the only continuity.
- Non-trivial logic gets a test. `flutter test` runs them; no device needed.
- Comment the native layer with *why* a choice was made, so nobody refactors the
  reliability out of it later.
- Never commit keystores, `key.properties`, or anything user-identifying.

## Build / run

```bash
flutter pub get
flutter analyze && flutter test
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb logcat -s DoseKeeper/Receiver DoseKeeper/Service   # watch the alarm pipeline
```

Flutter lives at `/home/susiee/development/flutter/bin/flutter` (not on PATH).
