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
 * - dosekeeper_storage_moved: which of these were moved over from ordinary storage
 * Notes, schedules, history and the database stay in ordinary storage, as does
 * dosekeeper_backup (the backup folder), which only runs unlocked.
 */
object DeviceStorage {
    private val NAMES = listOf(
        "dosekeeper_armed_alarms", BootReceiver.PREFS, "dosekeeper_answered_doses", "dosekeeper_settings",
    )

    /** Which files were moved over (or tried). Holds only these file names. */
    private const val MOVED = "dosekeeper_storage_moved"

    internal val migrated = mutableSetOf<String>() // internal: tests start each case afresh

    @Synchronized
    fun prefs(context: Context, name: String): SharedPreferences {
        val deviceContext = context.createDeviceProtectedStorageContext()
        if (!migrated.containsAll(NAMES + name) && isUnlocked(context)) {
            // Existing installs keep their registry and settings: moved over while unlocked --
            // MY_PACKAGE_REPLACED right after the update installs, at the latest. While locked
            // the old file can't be read, so this waits.
            // All of them on the first access, not each on its own, and each one tried only
            // ever once (recorded on disk): a move copies the old file over the new one, so a
            // later move would overwrite what was written here since (a Taken, a fired time).
            val moved = deviceContext.getSharedPreferences(MOVED, Context.MODE_PRIVATE)
            for (n in NAMES + name) {
                if (n in migrated) continue
                if (!moved.getBoolean(n, false)) {
                    if (!deviceContext.moveSharedPreferencesFrom(context, n)) {
                        // ponytail: a copy error (disk full) strands the old file. The next sync
                        // re-records every armed alarm here, and settings read as defaults.
                        Log.w("DoseKeeper/Storage", "couldn't move $n to device storage")
                    }
                    moved.edit().putBoolean(n, true).commit() // on disk before anything writes here
                }
                migrated.add(n)
            }
        }
        return deviceContext.getSharedPreferences(name, Context.MODE_PRIVATE)
    }

    fun isUnlocked(context: Context): Boolean =
        context.getSystemService(UserManager::class.java)?.isUserUnlocked == true
}
