package dev.susiee.dosekeeper

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Alarms do not survive a reboot. Flutter owns the schedule, so all this does is record
 * that a reboot happened; the Dart side reschedules everything on next launch, and we
 * proactively start the app's headless engine work via a pending-reschedule flag.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "boot/replace broadcast: ${intent.action}")
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_NEEDS_RESCHEDULE, true)
            .apply()
    }

    companion object {
        private const val TAG = "DoseKeeper/Boot"
        const val PREFS = "dosekeeper_native"
        const val KEY_NEEDS_RESCHEDULE = "needs_reschedule"
    }
}
