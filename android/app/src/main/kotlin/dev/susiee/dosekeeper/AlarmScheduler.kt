package dev.susiee.dosekeeper

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONObject

/**
 * Schedules dose alarms.
 *
 * Uses setAlarmClock() rather than setExact*(): it is the only alarm API Android treats
 * as a genuine user-facing alarm clock. It is exempt from Doze, survives App Standby
 * buckets, and shows the alarm icon in the status bar. Aggressive OEM battery managers
 * (ColorOS in particular) will happily kill everything else.
 */
object AlarmScheduler {
    private const val REGISTRY = "dosekeeper_armed_alarms"
    private const val LATE_RING_WINDOW_MS = 2 * 60 * 60 * 1000L // = Dose.missedAfter
    private const val BOOT_RING_DELAY_MS = 10 * 1000L

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
        remember(context, doseId, triggerAtMillis, medName, dosage)
    }

    fun cancel(context: Context, doseId: Long) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        broadcast(context, doseId, PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
            ?.let { am.cancel(it); it.cancel() }
        forget(context, doseId)
    }

    // --- surviving a reboot ---
    //
    // Android deletes every app's alarms when the phone restarts. The schedule itself
    // lives in Dart's database, but Dart only runs when the app is opened -- so before
    // this, a reboot (an overnight OS update, the battery dying and being recharged)
    // left NO alarms armed until the user happened to open the app: the 07:00 dose
    // would silently never ring. So every armed alarm is also recorded here, natively,
    // and BootReceiver re-arms them straight from this list without needing Dart.

    private fun registry(context: Context) =
        context.getSharedPreferences(REGISTRY, Context.MODE_PRIVATE)

    private fun remember(context: Context, doseId: Long, triggerAt: Long, medName: String, dosage: String) {
        val entry = JSONObject()
            .put("triggerAt", triggerAt)
            .put("medName", medName)
            .put("dosage", dosage)
        registry(context).edit().putString(doseId.toString(), entry.toString()).apply()
    }

    /** The alarm is no longer armed: it fired, or was cancelled. */
    fun forget(context: Context, doseId: Long) {
        registry(context).edit().remove(doseId.toString()).apply()
    }

    /**
     * Re-arms everything that was armed before a reboot. A dose whose time passed while
     * the phone was off still rings, just late -- late beats never -- unless it is past
     * the app's missed-dose grace period (Dose.missedAfter in Dart), by which point it is
     * simply missed, and the app's missed-dose notification takes over.
     */
    fun rearmAll(context: Context, now: Long = System.currentTimeMillis()) {
        val stale = mutableListOf<String>()
        for ((key, value) in registry(context).all) {
            val doseId = key.toLongOrNull()
            val entry = (value as? String)?.let { runCatching { JSONObject(it) }.getOrNull() }
            val triggerAt = entry?.optLong("triggerAt", 0L) ?: 0L
            if (doseId == null || entry == null || triggerAt < now - LATE_RING_WINDOW_MS) {
                stale.add(key)
                continue
            }
            schedule(
                context,
                doseId,
                maxOf(triggerAt, now + BOOT_RING_DELAY_MS),
                entry.optString("medName", "Medication"),
                entry.optString("dosage", ""),
            )
        }
        if (stale.isNotEmpty()) {
            val editor = registry(context).edit()
            stale.forEach { editor.remove(it) }
            editor.apply()
        }
    }

    /** False on API 31-32 when the user has revoked exact-alarm access. */
    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }
}
