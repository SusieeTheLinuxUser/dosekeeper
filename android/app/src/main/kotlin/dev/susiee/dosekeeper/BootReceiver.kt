package dev.susiee.dosekeeper

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Alarms do not survive a reboot (or, on some OEM builds, an app update). This re-arms
 * them natively from AlarmScheduler's own record of what was armed -- without waiting
 * for the user to open the app, which used to be the only time Dart ran.
 *
 * Time/time-zone changes and the daily safety net arrive here too. Their alarms are
 * still armed (only the wall-clock meaning changed, or nothing changed), so they skip
 * the re-arm and only kick off a background Dart sync -- which re-materialises doses
 * on the new clock and tops the horizon up (see BackgroundSync).
 *
 * ColorOS only delivers these broadcasts to apps allowed to "auto-launch"; the user has
 * to allow that for DoseKeeper in the phone's settings (see README).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "broadcast: ${intent.action}")
        when (intent.action) {
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_TIME_CHANGED,
            BackgroundSync.ACTION_DAILY_SYNC,
            -> Unit // alarms are still armed; only Dart's picture needs refreshing

            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
            -> AlarmScheduler.rearmAll(context) // boot/replace: alarms are gone

            // Exported, so any app can send this anything. Keep in step with the manifest.
            else -> return
        }
        BackgroundSync.armSafetyNet(context) // first: nothing below may fail before this
        BackgroundSync.request(context, goAsync())
    }

    companion object {
        private const val TAG = "DoseKeeper/Boot"
        const val PREFS = "dosekeeper_native"
    }
}
