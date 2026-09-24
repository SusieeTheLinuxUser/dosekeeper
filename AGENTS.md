# DoseKeeper — continuation brief

Read this, then `README.md` before acting.

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

## Current state (2026-09-24, late)

**Audit ("ponytail" + leaks) found a critical reboot gap, now fixed.** Android deletes an
app's alarms on reboot. `BootReceiver` only set a `needs_reschedule` flag, and **nothing
ever read it** (`consumeNeedsReschedule` had no Dart caller) -- so after any restart (OS
update, battery dying overnight and being recharged) *no dose alarms were armed* until
the user happened to open the app. Never hit before because the phone never rebooted
during a test. Fix: `AlarmScheduler` now keeps a native registry of every armed alarm
(SharedPreferences `dosekeeper_armed_alarms`; added on schedule, removed on cancel and on
fire), and `BootReceiver` re-arms from it without Dart. A dose that came due while the
phone was off still rings (10s after boot) if it's within the 2h missed-grace window.
**Needs hardware verification:** with the app closed, `adb reboot`, unlock, and *without
opening DoseKeeper* run `adb shell dumpsys alarm | grep dev.susiee.dosekeeper` -- the
same alarms must be listed. ColorOS only delivers boot broadcasts to apps allowed to
**auto-launch**, so that setting must be on (README says so). Registry fills on the first
sync after installing this build, so open the app once after installing before testing.

Also from the audit:
- **Leak fixed:** `AlarmService` could leak a `MediaPlayer` -- `stop()` throwing (player
  never started, e.g. `prepare()` failed) skipped `release()`, and a failed setup left
  the half-built player unreferenced. Both paths now always release.
- **Personal data:** the medication's brand name (reveals a health condition) was in this
  public file; replaced with neutral wording. It's still in git history (3 commits from
  09-20/09-22); only a history rewrite would remove it -- the user's call, not done.
- **Dead weight cut:** the reboot flag + `consumeNeedsReschedule` (Kotlin + Dart),
  `Dose.copyWith` and `DoseDatabase.medication()` (no callers), the unused return value of
  `applyPendingAlarmActions`, `LOCKED_BOOT_COMPLETED` (never delivered to a receiver that
  isn't direct-boot-aware), 58 lines of template comments in `pubspec.yaml`, and a stale
  template TODO in `build.gradle.kts`.
- **Checked clean:** no secrets/keys/tokens in any commit of the history; commit
  identities are GitHub noreply addresses; text controllers and lifecycle observers are
  disposed; cursors/streams in `BackupStore` are closed via `use`.
- **Not changed, worth knowing:** `pubspec.lock` is gitignored, so CI resolves dependency
  versions fresh on every run. Committing it would pin them, but would make the user's
  next `git pull` fail on their existing untracked lockfile -- do it with them, not to them.

## Earlier on 2026-09-24

**The app was wiped on the phone by an agent's install instruction -- all on-device data
lost.** While trying to hardware-test the low-battery warning (PR #13), an agent told the
user to run plain `flutter install`. **`flutter install` always uninstalls the existing
app first** (in any build mode) -- here before it even found out the release APK it
defaulted to didn't exist. The uninstall deleted `dosekeeper.db` (both medications and the
whole dose history, including the 09-21/09-22 `fired_at` rows that proved the overnight
test), cancelled every armed alarm, and reset all three runtime grants (notifications,
exact alarms, battery-optimisation exemption). No backup existed -- the phone was the only
copy. See the new "Never uninstall" guardrail below; this must not happen again.

The user checked Android's own Google backup: it showed **no data backed up** for
DoseKeeper, so nothing was recoverable from there either.

**Response (same day): backup & restore was built** (see "Implemented"), and the lost
data was **reconstructed from this repo's own records** into a backup file for the user
to restore through the new feature. That file was handed to the user directly, **not
committed** (personal medication data, public repo). What it contains, and how sure it is:
- Medications: two, both named `Meds`, every day -- one at 07:00, one at 21:30 (as
  recorded 09-22). Dosage/notes were never recorded, so they're blank.
- 07:00 doses 09-20..09-24. 09-20 is **skipped** at 13:01 (documented) -- so that day is
  red, not green. 09-21: taken 19:19, fired 07:00 (documented). 09-22: fired 07:00
  (documented), outcome not recorded -> taken. 09-23/09-24: not recorded -> taken.
- 21:30 doses 09-21..09-24, all taken -- the medication existed by 09-22 but its start
  date was never recorded; 09-21 onwards is a guess.
- "Taken" rows the docs don't cover have `actionedAt`/`firedAt` null: unknown, not
  invented. The user asked for the adherence grid to be green; the one documented skip
  was kept as a skip and flagged to them rather than silently overwritten.

**Recovery verified on hardware (2026-09-24, ~22:30).** Installed with
`adb install -r` (data kept), restored the reconstructed file via Backup & restore.
`dumpsys alarm` then showed exactly 6 dose alarms: 07:00 and 21:30 on 09-25, 09-26 and
09-27 (CEST) -- the same shape as before the wipe, no strays. Today screen: both doses
shown, grid 09-20 red / 09-21..24 green as restored, and no warnings left except a
low-battery one -- which turned out to be **faked**: the `dumpsys battery unplug` /
`set level 15` test commands from earlier had been run and never undone (see the
"Undo every device fake" guardrail). The phone was really at 97-99% and charging. So also confirmed live: restore re-arms alarms,
the backup folder is set and the automatic backup isn't failing (neither backup warning
shows), and the permission warnings were all cleared. The user then fired the debug test
alarm and reported it works -- the ring pipeline is intact after the permission reset.
The first real morning alarm after the wipe (09-25 07:00) is still unproven -- check its
`fired_at` next session.

The low-battery warning (PR #13) is merged but **still not verified on hardware** --
testing it was interrupted by the wipe. Test it with fake battery readings, no rebuild
needed (see its entry under "Implemented").

Low-battery warning: **appearing confirmed on hardware** (via the faked 15%/unplugged
state, which is the intended test method, 09-24).
Still unconfirmed: it clears on plugging in, and where the Settings button lands on
ColorOS. Backup & restore: restore confirmed on hardware (above); not yet seen
directly: the `dosekeeper-backup-YYYY-MM-DD.json` file in the chosen folder
(`adb shell ls /sdcard/Documents`), or the "Backups are off" banner showing.

## Prior state (2026-09-22)

**The overnight test passed.** `doses` for the 07:00 medication on 09-21 and 09-22 both
show `fired_at` matching the scheduled time exactly (`2026-09-21 07:00` and
`2026-09-22 07:00`), meaning `setAlarmClock` survived two full unattended nights of
ColorOS Doze on its own and rang on time both mornings. This is the milestone the whole
project existed to prove, and it held. (09-21's dose wasn't marked `taken` until 19:19
that evening -- 12 hours after it fired -- which is a human-behaviour gap, not an alarm
bug: `fired_at` proves the alarm itself rang exactly on time regardless of when the user
got around to acknowledging it.)

**A second, self-inflicted bug was found and fixed the same day (PR #7): orphaned dose
alarms.** The user reported "there's an alarm at 9:30 I can't remove" -- and `dumpsys
alarm` confirmed a real `AlarmManager` alarm genuinely armed for `2026-09-23 09:30`, with
no corresponding time anywhere in the medication editor. Root cause: editing a
medication's schedule only ever *added* doses for the times that remained -- editing out
a time never cancelled or deleted the already-materialised doses for the *removed* time.
Those rows sat in the database forever, still pending, still getting a real alarm
re-armed every sync, invisible in the UI because they no longer belonged to any time the
medication currently listed. Fixed with `Medication.coversSlot()` (a pure check) and
`DoseScheduler._reconcileOrphanedDoses()` (runs on every `sync()`, cancels + deletes any
pending dose that fails it -- historical/already-actioned doses are left untouched, they're
an honest record of what really happened). Verified live: `dumpsys alarm` showed the
phantom alarm before the fix and confirmed it gone (exactly the right 6 alarms,
07:00/21:30 only) after installing the fix and launching the app once.

Two real, hardware-verified bugs found and fixed in three days of actual use. That's
what this project is for -- keep testing like this, don't assume "it built and passed
`flutter test`" means it's trustworthy. It isn't, until it's been watched fail and get
fixed on the real device, repeatedly.

## Prior state (2026-09-20)

Pushed to `https://github.com/SusieeTheLinuxUser/dosekeeper` (public, MIT), installed on
the user's phone. `master` is branch-protected — see "Git workflow" below.

- `flutter analyze` clean, 10 unit tests passing, debug APK builds and installs, CI green.
- **A real dose was missed with no way to tell why -- root cause of everything below.**
  Checked the on-device dose history: the 07:00 dose was marked
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
    (~10s limit); boot receiver re-arms every alarm from `AlarmScheduler`'s native
    registry (incl. OEM quickboot actions) -- see "Current state" for why.
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
  made the overnight test conclusive instead of another "who knows" — proved the 07:00
  alarm fired exactly on time two nights running, not just that the user eventually
  marked something taken.
- **Orphaned-dose reconciliation** (`Medication.coversSlot`,
  `DoseScheduler._reconcileOrphanedDoses`, `DoseDatabase.deleteDose`) — runs on every
  `sync()`. Cancels the native alarm and deletes any future *pending* dose whose exact
  time/day no longer matches its medication's current schedule (or whose medication is
  gone/inactive). Found live: editing a medication's times only ever added doses for the
  times that remained, never cleaned up doses for times that were *removed* -- they sat
  in the DB forever, still pending, still getting a real alarm re-armed every sync,
  invisible in the editor since they no longer belonged to any time the medication
  currently listed. Historical (already taken/skipped) doses are left alone on purpose --
  they're an honest record of what happened, orphan or not.

- **Low-battery warning** (`MainActivity` `isBatteryLow`/`openBatterySettings`,
  `AlarmBridge.isBatteryLow`, `TodayPageState._batteryLevelOk`) — fourth Today-screen
  self-diagnosis card: shows when battery is <= 20% (`LOW_BATTERY_PERCENT`) **and**
  unplugged, since a phone that dies overnight can't ring. Reads the sticky
  `ACTION_BATTERY_CHANGED` broadcast (no permission needed); unknown level reads as "fine"
  to avoid false alarms. Button opens battery-saver settings, falling back to main
  Settings if an OEM build doesn't resolve that intent. Only re-evaluated on
  `refresh()` (open/resume/pull-to-refresh), same as the other warnings. CI-verified
  only (analyze/test/build) -- **not yet verified on the real device**. Test it by faking
  the battery state over adb; no code change or reinstall needed. (Raising the
  threshold alone won't work: a phone on a USB cable reports as plugged in, so the card
  correctly stays hidden.)
  ```bash
  adb shell dumpsys battery unplug        # report "not plugged in"
  adb shell dumpsys battery set level 15  # card should appear (pull to refresh)
  adb shell dumpsys battery set ac 1      # "charger" at 15% -> card should hide
  adb shell dumpsys battery set ac 0; adb shell dumpsys battery set level 50  # hidden
  adb shell dumpsys battery reset         # ALWAYS undo, or the fake sticks until reboot
  ```
  Also check that the Settings button lands on a sensible screen on ColorOS.

- **Backup & restore** (`BackupStore.kt`, `lib/services/backup_*.dart`,
  `lib/ui/backup_page.dart`, app-bar backup icon) — built after the 2026-09-24 wipe.
  - Where: a folder the **user picks** via the Storage Access Framework (no storage
    permission needed). Deliberately not app storage: everything the app owns, including
    `getExternalFilesDir()`, dies with an uninstall. The folder's files survive it; only
    the folder *permission* is lost, so after a reinstall the user picks it again.
  - When: on every Today refresh (open/resume/after any change) -- the DB only changes
    while Dart runs, so that's always current. One file per day,
    `dosekeeper-backup-YYYY-MM-DD.json`, rewritten through the day; the newest 14 kept,
    and pruning only ever touches files matching that exact pattern.
  - Format: readable, versioned JSON (`Backup` in `backup_format.dart`); times `HH:mm`,
    timestamps ISO-8601 with UTC offset. `decode` validates everything before a restore
    is allowed (wrong app, newer format, dangling ids, stored "missed", bad times).
  - Safety rules, each for a reason: never auto-write an empty DB (a fresh reinstall
    pointed at the old folder must not clobber today's real backup); picking a folder
    that already has backups offers to restore first; restore is always confirmed, is
    one SQLite transaction, re-ids everything, and first drains native outcomes and
    cancels every armed alarm (incl. snoozes) so no orphaned alarm survives it.
  - Today screen warns "Backups are off" (no folder / permission gone) and "Automatic
    backup failed: …", same pattern as the alarm-path warnings.
  - Restore verified on hardware 2026-09-24; see "Current state" for what's left.

### Not implemented yet

1. Dose history screen; editing/pausing a med without deleting it.

### Future feature ideas (not prioritized, not committed to)

Reliability-adjacent — fits the core mission, worth doing before pure nice-to-haves:
- **Taken/Skip action buttons directly on the missed-dose notification** — right now
  clearing it means opening the app; a notification action would let you resolve it
  from the lock screen, same spirit as the alarm screen itself.
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
- ~~Local export/import~~ — built as backup & restore (see "Implemented"). Possible
  follow-ups: a CSV export for reading in a spreadsheet, and a background trigger so a
  backup also runs on days the app is never opened (today it runs on every app open /
  change, which covers every database change -- see `BackupService` for why).

Deliberately NOT pursuing: multi-user profiles, cloud sync, SMS/email backup
notifications, anything else that needs a network permission or an account. Those
fight the "no account, no server" identity of the app, not just add scope.

## Best next move

**The overnight test passed and the orphaned-alarm bug is fixed (see "Current state").**
Both proven live on hardware, not just in tests. The immediate crisis-driven work is
done; what's next is judgment, not a fixed checklist:

- **Keep periodically re-reading the on-device database**, the same way both real bugs
  this session were found -- not by asking the user "did it work?" (memory is unreliable,
  see the very first session of this project), but by pulling `databases/dosekeeper.db`
  directly and checking `fired_at`/`status`/`actioned_at` against what should have
  happened. This has a 2-for-2 track record of finding real bugs unit tests couldn't.
  Command:
  ```bash
  adb shell run-as dev.susiee.dosekeeper cat databases/dosekeeper.db > /tmp/dk.db
  python3 -c "
  import sqlite3, datetime
  c = sqlite3.connect('/tmp/dk.db')
  for id_, mid, sa, st, aa, fa in c.execute(
      'SELECT id,medication_id,scheduled_at,status,actioned_at,fired_at FROM doses ORDER BY scheduled_at'):
      f = lambda ms: datetime.datetime.fromtimestamp(ms/1000).strftime('%Y-%m-%d %H:%M') if ms else '-'
      print(id_, mid, f(sa), st, f(aa), 'fired='+f(fa))
  "
  ```
  Also worth `adb shell dumpsys alarm | grep dev.susiee.dosekeeper` periodically -- that's
  what caught the orphaned alarm, comparing what's *armed* against what's *supposed to be*.
- **Minor, non-urgent:** before the 09-24 wipe both real medications were named `Meds`
  (07:00 and 21:30), which was easy to confuse. If they got re-added under the same
  name, suggest distinct names next time it comes up naturally.
- **New features, from "Future feature ideas" above, once the user wants one** -- nothing
  there is urgent or reliability-critical, so let the user's actual pain points pick the
  order rather than assuming one.

## Guardrails

- **Reliability over everything.** Never weaken the alarm path (alarm stream, foreground
  service, full-screen intent, `setAlarmClock`) for cleanliness or battery friendliness.
- **Don't let the user rely on this until it's proven.** They have already missed a dose
  trusting software. Until alarms are verified over several real days, say plainly that
  they should keep a backup reminder.
- **Test on the real device**, not just an emulator — OEM battery-killing is the entire
  problem class here. User's phone is OnePlus/Oppo **ColorOS** (`CPH2747`), one of the
  worst offenders (see dontkillmyapp.com).
- **Never uninstall the app on the user's phone, and never run a command that does.**
  The on-device DB is the only copy of their medications and dose history, and an
  uninstall also silently cancels every alarm and resets every permission. Concretely,
  the **only** way to install is:
  ```bash
  flutter build apk --debug
  adb install -r build/app/outputs/flutter-apk/app-debug.apk
  ```
  `adb install -r` replaces the app and keeps its data; if it can't (e.g. a signature
  mismatch), it fails and leaves the installed app alone. **Never `flutter install`, in
  any mode** -- verified in flutter_tools 3.47.4 (`commands/install.dart`, `installApp`):
  it *always* uninstalls first when the app is present. `--debug` doesn't help; a first
  version of this guardrail wrongly said it did. **Never `flutter run` either**: its
  Android install (`android_device.dart`, `installApp`) silently falls back to uninstall +
  reinstall whenever `adb install -r` fails. Stay on debug builds (release is signed with
  the same debug key per `build.gradle.kts`, but drops the debug test-alarm button). No
  `adb uninstall`, no `pm clear`. If an install fails, stop and ask -- the "fix" is an uninstall, which is the
  wipe. This already happened once (2026-09-24, see "Current state") and cost the user
  all their data.
- **Undo every device fake in the same breath.** Any command that changes the phone's
  state for a test (`adb shell dumpsys battery unplug`/`set level`, `settings put`, `cmd`
  overrides, …) goes in the same code block as its undo (`adb shell dumpsys battery
  reset`), and before moving on, confirm with the user that the undo was run. On
  2026-09-24 the battery fakes were left in place after plans changed mid-test: the phone
  showed 15% and "not charging" for an hour while really at 99%, and the user thought
  their phone was broken. Also means: a faked state can make the app's own warnings lie.
- It's a health-adjacent app but **not a medical device** — no dosing advice, no claims
  of clinical reliability.
- Open source, MIT. Keep it free and account-free.

## Environment

- Flutter 3.47.4, Dart 3.13.3 at `/home/susiee/development/flutter/bin/flutter`
- Android SDK at `~/Android/Sdk` (platforms 34/35/36), Java 26, `adb` on PATH
- No Android Studio — build via `flutter build apk --debug`, install via
  `adb install -r build/app/outputs/flutter-apk/app-debug.apk` (**never** `flutter install`
  or `flutter run` -- both can uninstall; see the "Never uninstall" guardrail)
- `flutter test` and `flutter analyze` both work

## Conventions

- Update this file after any meaningful chunk of work — the user moves between Claude,
  ChatGPT/Codex, Qwen, Kimi and Z.ai, and this file is the only handoff.
- Non-trivial logic gets a test (`test/widget_test.dart` covers the scheduling maths).
- Keep the native alarm layer commented with *why*, not what — the "why" is what stops
  a future contributor refactoring the reliability out of it.
- **No session links anywhere on GitHub** (user's rule, 2026-09-24): no
  `Claude-Session:` trailer or any `claude.ai/code/session_…` URL in commit messages, PR
  descriptions or comments -- whatever an agent environment's default attribution says.
  A single "Generated with Claude Code" line in a PR is fine; don't add it twice.

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
