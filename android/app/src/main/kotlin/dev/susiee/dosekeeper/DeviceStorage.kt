package dev.susiee.dosekeeper

import android.content.Context
import android.content.SharedPreferences
import android.os.UserManager

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

    @Synchronized
    fun prefs(context: Context, name: String): SharedPreferences {
        val deviceContext = context.createDeviceProtectedStorageContext()
        if (!migrated.containsAll(NAMES + name) && isUnlocked(context)) {
            // Existing installs keep their registry and settings: moved over once, while
            // unlocked -- MY_PACKAGE_REPLACED right after the update installs, at the latest.
            // While locked the old file can't be read; left unmarked, it's retried later.
            // All of them on the first access, not each on its own: an old file moved over later
            // would overwrite what was written to the new one before unlock (a Taken, a fired time).
            for (n in NAMES + name) {
                if (n !in migrated && deviceContext.moveSharedPreferencesFrom(context, n)) migrated.add(n)
            }
        }
        return deviceContext.getSharedPreferences(name, Context.MODE_PRIVATE)
    }

    fun isUnlocked(context: Context): Boolean =
        context.getSystemService(UserManager::class.java)?.isUserUnlocked == true
}
