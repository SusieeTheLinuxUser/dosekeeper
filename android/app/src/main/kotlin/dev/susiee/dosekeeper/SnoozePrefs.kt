package dev.susiee.dosekeeper

import android.content.Context

/**
 * The user's snooze length, in minutes. Stored natively (its own SharedPreferences file)
 * because the alarm screen snoozes while the Dart engine may not be running at all --
 * Dart only ever reads/writes it through the MethodChannel for the settings UI.
 *
 * Not in the JSON folder backup: that holds medications and dose history only. Google
 * backup (opt-in) does carry it, like every other preference, which is fine: a setting
 * following the user to a new phone is what they'd expect.
 */
object SnoozePrefs {
    private const val PREFS = "dosekeeper_settings"
    private const val KEY_SNOOZE_MINUTES = "snooze_minutes"

    val ALLOWED = setOf(5, 10, 15, 30)

    /** Missing/corrupt/unknown value falls back to 10, the historical hardcoded length. */
    fun snoozeMinutes(context: Context): Int {
        val v = prefs(context).getInt(KEY_SNOOZE_MINUTES, 10)
        return if (v in ALLOWED) v else 10
    }

    fun setSnoozeMinutes(context: Context, minutes: Int) {
        // Only the allowed choices are ever written, so the fallback above stays a fallback.
        if (minutes !in ALLOWED) return
        prefs(context).edit().putInt(KEY_SNOOZE_MINUTES, minutes).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}