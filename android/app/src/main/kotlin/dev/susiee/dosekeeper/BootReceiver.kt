package dev.susiee.dosekeeper

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Alarms do not survive a reboot (or, on some OEM builds, an app update). This re-arms
 * them natively from AlarmScheduler's own record of what was armed -- without waiting
 * for the user to open the app, which is the only time Dart runs.
 *
 * ColorOS only delivers these broadcasts to apps allowed to "auto-launch"; the user has
 * to allow that for DoseKeeper in the phone's settings (see README).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "boot/replace broadcast: ${intent.action}")
        AlarmScheduler.rearmAll(context)
    }

    companion object {
        private const val TAG = "DoseKeeper/Boot"
        const val PREFS = "dosekeeper_native"
    }
}
