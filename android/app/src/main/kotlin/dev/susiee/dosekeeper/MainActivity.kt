package dev.susiee.dosekeeper

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Dart (which owns the schedule and the database) to the native alarm layer
 * (which owns actually ringing on time).
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scheduleDose" -> {
                        AlarmScheduler.schedule(
                            context = this,
                            doseId = (call.argument<Number>("doseId")!!).toLong(),
                            triggerAtMillis = (call.argument<Number>("triggerAt")!!).toLong(),
                            medName = call.argument<String>("medName") ?: "Medication",
                            dosage = call.argument<String>("dosage") ?: "",
                        )
                        result.success(true)
                    }

                    "cancelDose" -> {
                        AlarmScheduler.cancel(this, (call.argument<Number>("doseId")!!).toLong())
                        result.success(true)
                    }

                    "canScheduleExact" -> result.success(AlarmScheduler.canScheduleExact(this))

                    "openExactAlarmSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            startActivity(
                                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                    .setData(Uri.parse("package:$packageName")),
                            )
                        }
                        result.success(true)
                    }

                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }

                    "requestIgnoreBatteryOptimizations" -> {
                        startActivity(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                .setData(Uri.parse("package:$packageName")),
                        )
                        result.success(true)
                    }

                    /**
                     * POST_NOTIFICATIONS is a dangerous runtime permission on API 33+. Declaring
                     * it in the manifest grants nothing -- without this the OS silently drops the
                     * foreground-service notification, which silently drops the full-screen
                     * intent with it. The alarm still rings (audio is independent), but the
                     * lockscreen takeover never happens. Below 33 the permission does not exist
                     * and notifications are allowed by default.
                     */
                    "hasNotificationPermission" -> {
                        val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                            ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.POST_NOTIFICATIONS,
                            ) == PackageManager.PERMISSION_GRANTED
                        result.success(granted)
                    }

                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                0,
                            )
                        }
                        result.success(true)
                    }

                    /** Outcomes the native alarm screen recorded while Dart wasn't running. */
                    "drainPendingActions" -> {
                        val prefs = getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
                        val out = mutableListOf<Map<String, Any>>()
                        val editor = prefs.edit()
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
                                    editor.remove(key).remove("pending_action_at_$doseId")
                                }
                            }
                        }
                        editor.apply()
                        result.success(out)
                    }

                    "consumeNeedsReschedule" -> {
                        val prefs = getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
                        val needs = prefs.getBoolean(BootReceiver.KEY_NEEDS_RESCHEDULE, false)
                        prefs.edit().putBoolean(BootReceiver.KEY_NEEDS_RESCHEDULE, false).apply()
                        result.success(needs)
                    }

                    /** An overdue dose exists -- show/update the undismissable reminder. */
                    "updateOutstandingNotification" -> {
                        OutstandingNotifier.show(
                            this,
                            title = call.argument<String>("title") ?: "Missed dose",
                            text = call.argument<String>("text") ?: "",
                        )
                        result.success(true)
                    }

                    /** No more overdue doses -- clear the reminder. */
                    "clearOutstandingNotification" -> {
                        OutstandingNotifier.clear(this)
                        result.success(true)
                    }

                    /** Fire a test alarm N seconds out, to prove the pipeline end to end. */
                    "testAlarm" -> {
                        val seconds = (call.argument<Number>("seconds") ?: 10).toLong()
                        AlarmScheduler.schedule(
                            context = this,
                            doseId = 999_999L,
                            triggerAtMillis = System.currentTimeMillis() + seconds * 1000,
                            medName = call.argument<String>("medName") ?: "Test alarm",
                            dosage = call.argument<String>("dosage") ?: "",
                        )
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    companion object { private const val CHANNEL = "dev.susiee.dosekeeper/alarms" }
}
