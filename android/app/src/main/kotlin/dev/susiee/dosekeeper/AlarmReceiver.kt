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

        val serviceIntent = Intent(context, AlarmService::class.java).apply {
            action = AlarmService.ACTION_RING
            putExtras(intent)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }

    companion object {
        private const val TAG = "DoseKeeper/Receiver"
        const val KEY_FIRED_PREFIX = "fired_at_"
    }
}
