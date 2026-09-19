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

    companion object { private const val TAG = "DoseKeeper/Receiver" }
}
