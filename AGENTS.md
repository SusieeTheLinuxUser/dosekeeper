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
  GitHub-style adherence grid on the Today screen, `doses.fired_at` tracking, orphaned-dose
  reconciliation (`Medication.coversSlot`, `DoseScheduler._reconcileOrphanedDoses`).
- Passing: `flutter analyze` clean, 13 unit tests, debug APK builds, installed on the phone, CI green.
- **Overnight test PASSED (2026-09-21 and 09-22):** `fired_at` on both mornings' 07:00
  doses matches the scheduled time exactly -- `setAlarmClock` survived unattended ColorOS
  Doze overnight, twice. This was the project's central open question; it's answered.
- **A second real bug found and fixed the same week (PR #7): orphaned dose alarms.**
  Editing a medication's schedule only ever added doses for times that remained, never
  cleaned up doses for times that were *removed* -- a real `AlarmManager` alarm stayed
  armed for a time invisible in the editor. Fixed and verified live via `dumpsys alarm`
  before/after. Full story in `CLAUDE.md` "Current state".
- **Two real, hardware-verified bugs found via actual use in one week.** Keep reading the
  on-device DB (`databases/dosekeeper.db`) and `dumpsys alarm` periodically rather than
  trusting `flutter test` alone or the user's memory of what happened -- see `CLAUDE.md`
  "Best next move" for the exact commands.
- Not built yet: dose history screen; editing/pausing a med without deleting it; export.

## Safety and honesty

- Do not imply the app is proven until alarms have been verified over several real days.
  Tell the user plainly to keep a backup reminder until then.
- Health-adjacent, **not a medical device**: no dosing advice, no clinical claims.
- Test on the real phone (OnePlus/Oppo ColorOS `CPH2747`), not just an emulator —
  OEM process-killing is the entire problem class. See dontkillmyapp.com.

## Working conventions

- Remote is `https://github.com/SusieeTheLinuxUser/dosekeeper` (public). **`master` is
  branch-protected: direct pushes are rejected.** Work on a feature/fix branch, push it,
  open a PR (`gh pr create`), wait for CI (analyze + test + debug APK build) to pass, then
  merge (`gh pr merge --merge`). This applies to every session/agent, not just this one.
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
