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

Pushed to `https://github.com/SusieeTheLinuxUser/dosekeeper` (public, MIT), installed on
the user's phone. `master` is branch-protected — see "Git workflow" below.

- `flutter analyze` clean, 10 unit tests passing, debug APK builds and installs, CI green.
- **A real dose was missed with no way to tell why -- root cause of everything below.**
  Checked the on-device dose history: a Medikinet dose scheduled for 07:00 was marked
  `skipped`, `actioned_at` 13:01 -- six hours late, and completely ambiguous. Did the
  alarm never ring (a real bug, the exact failure mode this app exists to catch), or did
  it ring and get dealt with hours later (a human choice, not a bug at all)? The database
  only recorded what the *user* did, never whether the *alarm* itself fired. No way to
  tell the two apart after the fact.
- **Fixed: `doses.fired_at` now records the moment the OS actually delivers the alarm
  broadcast, written by `AlarmReceiver.onReceive()` before anything downstream (ringing,
  the user's response) can fail or go unrecorded.** v1->v2 SQLite migration, verified live
  against the phone's real production database (not just a fresh install) -- schema
  upgraded to v2, existing dose history intact, `fired_at` correctly `NULL` on rows that
  predate the feature. **Verified end-to-end on hardware**, not just in tests: fired the
  debug test alarm, polled the on-device SharedPreferences file every second by hand, and
  watched `fired_at_999999` appear at exactly +10s (matching the alarm's own delay to the
  second) and persist until the next sync drained it. Today screen now shows "missed
  (alarm may not have rung)" vs. plain "missed" using this. Merged as PR #5.
  **This directly unblocks the overnight test** (see "Best next move") -- without it, an
  overnight failure would have been just as unexplainable as today's was.
- **First real-world alarm test (2026-09-20, 09:00): partial success, one real bug found.**
  Three test medications (leftover from earlier manual testing, all coincidentally at
  09:00) fired while the user was actively using another app (scrolling, phone unlocked)
  — the full-screen intent correctly took over the screen and interrupted them, which is
  arguably a stronger proof than the earlier locked-screen test. **But:** tapping "Taken"
  closed the alarm screen without stopping the sound; the user had to force-close the app.
  Root cause: `AlarmService.startRinging()` created a new `MediaPlayer` on every `RING`
  intent without stopping the previous one first. Three doses at the same instant meant
  three overlapping `MediaPlayer`s; dismissing one only ever stopped the most recently
  created one, leaving the others orphaned and looping forever, un-stoppable short of
  killing the process. Fixed by releasing all ringing resources (player/vibrator/wakelock)
  at the top of `startRinging()`, not just in `onDestroy()`. **Confirmed fixed (2026-09-20,
  09:19):** fired a single debug test alarm on the rebuilt APK, tapped Taken, sound fully
  stopped — no force-close needed. (Side note from that test, not a bug: the full-screen
  activity didn't auto-launch immediately because the app happened to be in the foreground
  when it fired — Android only auto-launches a full-screen intent when the screen is
  off/locked or the posting app is backgrounded; foregrounded, it correctly falls back to
  a tappable notification instead. Expected behavior, not something to "fix".)
  **Still needed: a proper overnight test** (phone idle/locked for hours, not actively in
  use) — hasn't happened yet. Known remaining rough edge: if two doses genuinely overlap, the second
  one's ring silently replaces the first's on-screen alarm activity's underlying audio
  without updating what's on screen (stale medication name until dismissed) — acceptable
  for now since the critical defect (sound literally impossible to stop) is fixed; true
  concurrent-dose UX would need the alarm activity to track multiple pending doses, not
  built.
- **First real hardware alarm confirmed.** Added a debug-only "Test alarm (10s)" button
  (`AlarmBridge.testAlarm`, wired to the native `testAlarm` handler that already existed
  in `MainActivity.kt` but had no caller) and fired it through the real
  `AlarmManager.setAlarmClock()` path while the phone was locked. User confirmed: screen
  woke, full-screen alarm took over the lockscreen, audio played, Taken button worked.
  **Still needed before trusting it day-to-day: an overnight test.** One successful manual
  trigger is not the same as surviving ColorOS's background killer over hours asleep.
- **Bug found and fixed during this test:** the manifest declared `POST_NOTIFICATIONS`
  but nothing ever requested it at runtime (dangerous permission on API 33+). Without it
  the OS silently dropped the notification the full-screen intent rides on — audio still
  played (independent MediaPlayer path) but the lockscreen takeover would have silently
  failed. Added `hasNotificationPermission`/`requestNotificationPermission` to
  `MainActivity.kt` + `AlarmBridge`, and a Today-screen warning banner matching the
  existing exact-alarm/battery-optimisation pattern. This was a real silent-failure gap,
  exactly the class of bug this project exists to catch — glad we tested before relying
  on it.

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
- **Self-diagnosis** — Today screen warns if exact alarms are blocked, battery
  optimisation is on, or notification permission is denied, with one-tap links to the
  system settings/dialogs that fix each.
- **Persistent missed-dose notification** (`OutstandingNotifier.kt`, `DoseScheduler._updateOutstandingNotification`)
  — an ongoing, non-swipeable notification (separate channel from the ringing alarm,
  no sound) that shows whenever any dose is past its 2h missed-grace period and still
  pending. Recomputed on every `sync()` call (app open, resume, after saving a med, after
  marking a dose), so it clears itself once the dose is marked taken/skipped. Verified on
  device by inserting a fake overdue dose directly into the SQLite DB: notification
  appeared with the right medication name, survived a swipe-to-dismiss gesture, and
  cleared once the fake row was removed. Known gap: only updates when the app actually
  runs some code (open/resume) — there's no background job keeping it fresh purely from
  time passing while the app sits closed. Acceptable for now since the ringing alarm is
  the primary mechanism; this is the backstop for after that's been seen and ignored/missed.
- **GitHub-style adherence grid** (`lib/ui/adherence_grid.dart`) — on the Today screen,
  above the dose list. One column per week, one row per weekday, coloured by taken/total
  for that day (grey = no dose that day, red = fully missed, green shades = partial-to-full).
  Fixed a real bug while building it: `DoseDatabase.dailyAdherence()` counted a dose in a
  day's total the instant it was scheduled, before its time arrived -- so today showed
  solid red at 00:19 for doses due at 09:00 that hadn't happened yet. Fixed by excluding
  doses whose `scheduledAt` is still in the future from the count entirely. Caught by
  actually looking at a screenshot from the device, not just `flutter analyze`/`test`.
- **Debug test-alarm button** — app bar, `kDebugMode`-gated only, confirm-dialog gated
  too. Fires a real alarm N seconds out through the actual `setAlarmClock` pipeline.
  Use this for every future hardware check instead of waiting on a real medication's
  scheduled time. Confirmation dialog added after a scare: it sits on the shared app
  bar on every screen, and on this phone a tap of it got delayed by ColorOS's own
  alarm helper (`OplusAlarmManagerServiceHelper`) and fired minutes later, coinciding
  with the user adding a real medication and looking like the add flow itself was
  ringing alarms. It wasn't (verified via the on-device DB) — but an unconfirmed,
  always-visible "fire a real alarm" button was a real foot-gun regardless.
- **`doses.fired_at` tracking** (`AlarmReceiver.kt`, `MainActivity.drainFiredEvents`,
  `AlarmBridge.drainFiredEvents`, `DoseScheduler._applyFiredAlarmEvents`) — records the
  instant the OS delivers the alarm broadcast, independent of the user's response. See
  "Current state" above for the full story and the on-device verification. This is what
  makes the upcoming overnight test conclusive instead of another "who knows" — if the
  dose is still pending/missed tomorrow with `fired_at` set, that's the OS/Doze/ColorOS
  killing the ring itself; if `fired_at` is null, the alarm mechanism (`setAlarmClock`,
  the receiver) never fired at all. Two very different bugs, now distinguishable.

### Not implemented yet

1. Dose history screen; editing/pausing a med without deleting it; export.

### Future feature ideas (not prioritized, not committed to)

Reliability-adjacent — fits the core mission, worth doing before pure nice-to-haves:
- **Taken/Skip action buttons directly on the missed-dose notification** — right now
  clearing it means opening the app; a notification action would let you resolve it
  from the lock screen, same spirit as the alarm screen itself.
- **Low-battery warning on the Today screen** — same self-diagnosis pattern as the
  existing exact-alarm/battery-optimisation/notification-permission checks. A dead
  phone can't ring, and that's a failure mode entirely outside the alarm pipeline.
- **Gradually-increasing alarm volume** for heavy sleepers who sleep through a flat tone.

Quality of life:
- **Surface the `notes` field** — it already exists on `Medication` and round-trips
  through the DB, but nothing in the edit UI lets you set it or shows it anywhere
  (e.g. "take with food"). Cheapest item on this list; the model already supports it.
- **"As-needed" (PRN) medications** — no fixed schedule, just a manual log button for
  ad hoc doses. Common for real regimens (e.g. pain relief) that the current
  fixed-time/fixed-weekday model can't represent at all.
- **Adjustable snooze length** — hardcoded to 10 minutes in `AlarmActivity.SNOOZE_MS`.
- **Home-screen widget** showing the next dose at a glance.

Data ownership — fits "no account, no server":
- **Local export/import** (JSON or CSV) so switching phones doesn't mean starting over.
  A file the user controls, not a cloud account — stays consistent with the app's whole
  premise.

Deliberately NOT pursuing: multi-user profiles, cloud sync, SMS/email backup
notifications, anything else that needs a network permission or an account. Those
fight the "no account, no server" identity of the app, not just add scope.

## Best next move

**The overnight test is already armed and just needs to happen -- check the result,
don't set it up again.** State as of 2026-09-20 13:16: the leftover test medications are
already gone (only one real medication exists, `Medikinet, 1 tablet, 07:00 daily`), and
`AlarmManager` has real `07:00` alarms armed for the 21st/22nd/23rd, confirmed via
`adb shell dumpsys alarm` (RTC_WAKEUP, `exactAllowReason=policy_permission`,
`device_idle=--` meaning Doze isn't deferring it). Nothing needs setting up.

**To check the result, read the on-device database directly (source of truth, not the
user's memory -- that's literally why this session started):**
```bash
adb shell run-as dev.susiee.dosekeeper cat databases/dosekeeper.db > /tmp/dk.db
python3 -c "
import sqlite3, datetime
c = sqlite3.connect('/tmp/dk.db')
for id_, sa, st, aa, fa in c.execute(
    'SELECT id,scheduled_at,status,actioned_at,fired_at FROM doses ORDER BY scheduled_at'):
    f = lambda ms: datetime.datetime.fromtimestamp(ms/1000).strftime('%Y-%m-%d %H:%M') if ms else '-'
    print(id_, f(sa), st, f(aa), 'fired='+f(fa))
"
```
Look at the row for `2026-09-21 07:00`:
- **`fired_at` set + `status` = taken/skipped after a reasonable delay** -> it worked.
  The whole alarm pipeline survived a real, unattended, overnight Doze cycle. This is the
  milestone that would finally justify calling the app trustworthy -- update "What this
  is and why" and this file's framing once it's true, not before.
- **`fired_at` set but the user never interacted (still pending/missed, no `actioned_at`
  near 07:00)** -> the alarm fired correctly but something failed *after* that (ringing,
  full-screen intent, or the user genuinely slept through it) -- check `AlarmService`/the
  notification-permission state, and ask the user what they experienced.
- **`fired_at` still null well after 07:00** -> the alarm mechanism itself never fired --
  `AlarmReceiver` never ran. That points at the OS/ColorOS silently dropping the
  `setAlarmClock` registration, which would be a serious finding worth its own
  investigation (check `dumpsys alarm` again, check if the app got force-stopped, check
  ColorOS's own battery/autostart settings for the app).

Only after a clean overnight result should new features get added -- see "Future feature
ideas" above for what's next.

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

## Git workflow

Remote: `https://github.com/SusieeTheLinuxUser/dosekeeper` (public, MIT).

**`master` is branch-protected as of 2026-09-20:** PR required to merge, CI (`.github/workflows/ci.yml`:
`flutter analyze` + `flutter test` + `flutter build apk --debug`) must pass, force-push and
branch deletion blocked, enforced for admins too — so this applies even to the repo owner,
not just outside contributors. Direct `git push origin <branch>:master` will be rejected.

Normal flow for any change, agent or human:
1. Branch off `master`: `git checkout -b <kind>/<short-description>`.
2. Commit, push: `git push -u origin <branch>`.
3. `gh pr create --base master`.
4. Wait for the CI check to pass on the PR.
5. `gh pr merge --merge` (or ask the user to click merge on GitHub).

No required review count is set (solo maintainer) — the PR + passing CI is the gate, not a
second pair of eyes. Don't add required reviewers, CODEOWNERS, or multi-environment deploy
stages; this is a one-person open-source project, not a team repo.
