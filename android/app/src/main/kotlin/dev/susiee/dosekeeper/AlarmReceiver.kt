package dev.susiee.dosekeeper

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Fires at dose time. Does as little as possible here -- a BroadcastReceiver gets ~10s
 * before the system kills it, so all it does is hand off to the foreground service that
 * actually rings.
 */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val doseId = intent.getLongExtra(AlarmScheduler.EXTRA_DOSE_ID, -1L)
        Log.i(TAG, "alarm fired for dose $doseId")

        // Record that the OS actually delivered this broadcast, before anything else
        // that could go wrong (service start failing, ringing failing, the app crashing).
        // This is the ground truth for "did the alarm really fire" -- without it, a dose
        // that's still "skipped"/"missed" hours later is ambiguous: did the alarm never
        // ring (a real bug, the exact failure mode this app exists to catch), or did it
        // ring and get ignored/dealt with later (not a bug at all)? Recorded here, first,
        // so the answer survives even if everything downstream fails.
        context.getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong("$KEY_FIRED_PREFIX$doseId", System.currentTimeMillis())
            .apply()
        AlarmScheduler.forget(context, doseId) // fired: nothing left to re-arm after a reboot
        AlarmActivity.dueAgain(context, doseId) // due now: an alarm screen must list it

        val serviceIntent = Intent(context, AlarmService::class.java).apply {
            action = AlarmService.ACTION_RING
            putExtras(intent)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (e: IllegalStateException) { // ForegroundServiceStartNotAllowedException
            Log.w(TAG, "can't start the ringing service from the background", e)
            AlarmService.notifyInstead(
                context,
                doseId,
                intent.getStringExtra(AlarmScheduler.EXTRA_MED_NAME) ?: "Medication",
                intent.getStringExtra(AlarmScheduler.EXTRA_DOSAGE) ?: "",
            )
        }

        // Ring first: nothing may delay it, so the sync that tops the horizon up waits
        // a few seconds. Doses are at whole minutes anyway, so a sync a few seconds
        // after one can't straddle the next. No goAsync() here: Android holds this app's
        // next broadcast until this one finishes, which rang a second dose due at the
        // same moment 3 s late (seen on Android 16). The ringing service keeps the
        // process alive instead.
        BackgroundSync.request(context, delayMs = RING_FIRST_DELAY_MS)
    }

    companion object {
        private const val TAG = "DoseKeeper/Receiver"
        private const val RING_FIRST_DELAY_MS = 3_000L
        const val KEY_FIRED_PREFIX = "fired_at_"
    }
}
