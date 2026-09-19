package dev.susiee.dosekeeper

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Schedules dose alarms.
 *
 * Uses setAlarmClock() rather than setExact*(): it is the only alarm API Android treats
 * as a genuine user-facing alarm clock. It is exempt from Doze, survives App Standby
 * buckets, and shows the alarm icon in the status bar. Aggressive OEM battery managers
 * (ColorOS in particular) will happily kill everything else.
 */
object AlarmScheduler {
    const val EXTRA_DOSE_ID = "doseId"
    const val EXTRA_MED_NAME = "medName"
    const val EXTRA_DOSAGE = "dosage"
    const val EXTRA_TRIGGER_AT = "triggerAt"

    private fun broadcast(context: Context, doseId: Long, flags: Int): PendingIntent? {
        val intent = Intent(context, AlarmReceiver::class.java).apply {
            action = "dev.susiee.dosekeeper.ALARM_FIRE"
        }
        return PendingIntent.getBroadcast(context, doseId.toInt(), intent, flags)
    }

    fun schedule(
        context: Context,
        doseId: Long,
        triggerAtMillis: Long,
        medName: String,
        dosage: String,
    ) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        val fireIntent = Intent(context, AlarmReceiver::class.java).apply {
            action = "dev.susiee.dosekeeper.ALARM_FIRE"
            putExtra(EXTRA_DOSE_ID, doseId)
            putExtra(EXTRA_MED_NAME, medName)
            putExtra(EXTRA_DOSAGE, dosage)
            putExtra(EXTRA_TRIGGER_AT, triggerAtMillis)
        }
        val operation = PendingIntent.getBroadcast(
            context,
            doseId.toInt(),
            fireIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // Tapping the status-bar alarm icon opens the app.
        val showIntent = PendingIntent.getActivity(
            context,
            doseId.toInt(),
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        am.setAlarmClock(AlarmManager.AlarmClockInfo(triggerAtMillis, showIntent), operation)
    }

    fun cancel(context: Context, doseId: Long) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        broadcast(context, doseId, PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
            ?.let { am.cancel(it); it.cancel() }
    }

    /** False on API 31-32 when the user has revoked exact-alarm access. */
    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }
}
