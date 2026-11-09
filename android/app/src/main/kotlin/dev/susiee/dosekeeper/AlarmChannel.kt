package dev.susiee.dosekeeper

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The method-channel calls a background sync needs (see BackgroundSync): everything
 * DoseScheduler.sync() can invoke. They live here, not in MainActivity, so a headless
 * FlutterEngine -- started while the app is closed, with no activity -- can serve the
 * exact same Dart code path as the foreground app. Returns true when the call was one
 * of these (handled or errored), false so the caller's own `when` can take it.
 */
object AlarmChannel {

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "scheduleDose" -> {
                val doseId = (call.argument<Number>("doseId")!!).toLong()
                val triggerAt = (call.argument<Number>("triggerAt")!!).toLong()
                // Sync read this dose as upcoming, then its alarm fired while sync was
                // still running: a fired record already exists for it. Arming the now-past
                // time would ring it a second time at once -- so count it as done.
                val fired = context.getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
                    .contains("${AlarmReceiver.KEY_FIRED_PREFIX}$doseId")
                result.success(
                    fired && triggerAt <= System.currentTimeMillis() ||
                        AlarmScheduler.schedule(
                            context = context,
                            doseId = doseId,
                            triggerAtMillis = triggerAt,
                            medName = call.argument<String>("medName") ?: "Medication",
                            dosage = call.argument<String>("dosage") ?: "",
                        ),
                )
            }

            "cancelDose" -> {
                AlarmScheduler.cancel(context, (call.argument<Number>("doseId")!!).toLong())
                result.success(true)
            }

            /** Outcomes the native alarm screen recorded while Dart wasn't running. */
            "readPendingActions" -> {
                val prefs = context.getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
                val out = mutableListOf<Map<String, Any>>()
                prefs.all.forEach { (key, value) ->
                    if (key.startsWith("pending_action_") && !key.startsWith("pending_action_at_")) {
                        val doseId = key.removePrefix("pending_action_").toLongOrNull()
                        if (doseId != null) {
                            out.add(
                                mapOf(
                                    "doseId" to doseId,
                                    "action" to (value as? String ?: "TAKEN"),
                                    "at" to prefs.getLong("pending_action_at_$doseId", 0L),
                                ),
                            )
                        }
                    }
                }
                result.success(out)
            }

            /**
             * The database has this outcome, so the record can go. Not removed on read: a
             * sync dying in between (it can run with no screen open) would lose a Taken,
             * and a dose shown as missed can get taken twice. Only if it's still the same
             * record: the user may have answered again since it was read.
             */
            "ackPendingAction" -> {
                val doseId = (call.argument<Number>("doseId")!!).toLong()
                val at = (call.argument<Number>("at")!!).toLong()
                val prefs = context.getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
                if (prefs.getLong("pending_action_at_$doseId", 0L) == at) {
                    prefs.edit().remove("pending_action_$doseId").remove("pending_action_at_$doseId").apply()
                }
                result.success(true)
            }

            /**
             * When each alarm actually fired, per AlarmReceiver.KEY_FIRED_PREFIX.
             * Independent of readPendingActions: that records what the user *did*
             * about an alarm, this records whether the alarm *happened* at all --
             * the distinction that makes a missed dose attributable instead of a
             * mystery.
             */
            "drainFiredEvents" -> {
                val prefs = context.getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
                val out = mutableListOf<Map<String, Any>>()
                val editor = prefs.edit()
                prefs.all.forEach { (key, value) ->
                    if (key.startsWith(AlarmReceiver.KEY_FIRED_PREFIX)) {
                        val doseId = key.removePrefix(AlarmReceiver.KEY_FIRED_PREFIX).toLongOrNull()
                        if (doseId != null && value is Long) {
                            out.add(mapOf("doseId" to doseId, "firedAt" to value))
                            editor.remove(key)
                        }
                    }
                }
                editor.apply()
                result.success(out)
            }

            /** An overdue dose exists -- show/update the reminder. */
            "updateOutstandingNotification" -> {
                OutstandingNotifier.show(
                    context,
                    title = call.argument<String>("title") ?: "Missed dose",
                    text = call.argument<String>("text") ?: "",
                    shownAt = call.argument<Number>("shownAt")?.toLong() ?: 0L,
                    // Exactly one missed dose: the notification gets Taken/Skip buttons.
                    doseId = call.argument<Number>("doseId")?.toLong(),
                )
                result.success(true)
            }

            /** Doses overdue by this time were swiped away by the user; 0 if none. */
            "outstandingDismissedThrough" -> {
                result.success(
                    context.getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
                        .getLong(OutstandingNotifier.KEY_DISMISSED_THROUGH, 0L),
                )
            }

            /** No more overdue doses -- clear the reminder. */
            "clearOutstandingNotification" -> {
                OutstandingNotifier.clear(context)
                result.success(true)
            }

            else -> return false
        }
        return true
    }
}
