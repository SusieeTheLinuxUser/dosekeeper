package dev.susiee.dosekeeper

import android.content.Context
import android.content.SharedPreferences
import android.os.UserManager
import android.util.Log

/**
 * The native prefs the alarm path needs, in device-protected storage: readable after a
 * restart before the first unlock (Direct Boot), so BootReceiver can re-arm and a dose
 * can ring and be answered on a locked phone. Ordinary storage stays locked until then.
 *
 * Readable before unlock means less protected, so only what ringing needs lives here:
 * - dosekeeper_armed_alarms: dose id -> trigger time, medication name, dosage (the alarm label)
 * - dosekeeper_native: fired_at / pending_action records (dose id, time, TAKEN/SNOOZE/SKIPPED),
 *   and when the missed-dose notification was last swiped
 * - dosekeeper_answered_doses: dose id -> when it was answered elsewhere
 * - dosekeeper_settings: snooze length, gradually-louder switch
 * Notes, schedules, history and the database stay in ordinary storage, as does
 * dosekeeper_backup (the backup folder), which only runs unlocked.
 */
object DeviceStorage {
    private val NAMES = listOf(
        "dosekeeper_armed_alarms", BootReceiver.PREFS, "dosekeeper_answered_doses", "dosekeeper_settings",
    )

    internal val migrated = mutableSetOf<String>() // internal: tests start each case afresh
    internal var movePreferencesForTest: ((Context, Context, String) -> Boolean)? = null

    @Synchronized
    fun prefs(context: Context, name: String): SharedPreferences {
        val deviceContext = context.createDeviceProtectedStorageContext()
        if (!migrated.containsAll(NAMES + name) && isUnlocked(context)) {
            // Existing installs keep their registry and settings: moved over while unlocked --
            // MY_PACKAGE_REPLACED right after the update installs, at the latest. While locked
            // the old file can't be read, so this waits. All of them on the first access, not
            // each on its own: a move copies the old file over the new one, so an old file
            // moved later would overwrite what was written here since (a Taken, a fired time).
            for (n in NAMES + name) {
                if (n in migrated) continue
                if (n == BootReceiver.PREFS &&
                    context.getSharedPreferences(n, Context.MODE_PRIVATE).all.isNotEmpty() &&
                    deviceContext.getSharedPreferences(n, Context.MODE_PRIVATE).all.isNotEmpty()
                ) {
                    // Both copies may now contain unacknowledged actions. Never let a retry
                    // replace device-protected writes with the older credential copy.
                    migrated.add(n)
                    continue
                }
                val moved = movePreferencesForTest?.invoke(deviceContext, context, n)
                    ?: deviceContext.moveSharedPreferencesFrom(context, n)
                if (!moved) {
                    if (n == BootReceiver.PREFS) {
                        // Unlike the alarm registry and settings, this file can contain a
                        // user's Taken/Snooze action that Dart has not acknowledged yet.
                        // Keep the credential copy so a failed move cannot discard it.
                        Log.e("DoseKeeper/Storage", "couldn't move $n; preserving pending actions")
                        migrated.add(n)
                        continue
                    }
                    // A copy error (disk full). The old file goes, so no later move can copy it
                    // over newer data here. ponytail: its contents are lost; the next sync
                    // re-records every armed alarm, and settings read as their defaults.
                    Log.w("DoseKeeper/Storage", "couldn't move $n to device storage; dropping it")
                    if (!context.deleteSharedPreferences(n)) Log.e("DoseKeeper/Storage", "couldn't delete old $n")
                }
                migrated.add(n)
            }
        }
        return deviceContext.getSharedPreferences(name, Context.MODE_PRIVATE)
    }

    fun isUnlocked(context: Context): Boolean =
        context.getSystemService(UserManager::class.java)?.isUserUnlocked == true
}
