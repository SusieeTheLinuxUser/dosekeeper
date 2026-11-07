package dev.susiee.dosekeeper

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.widget.Toast

/**
 * The ringing alarm screen. Appears over the lockscreen with the screen turned on.
 *
 * Deliberately NOT the Flutter activity: this must be able to show instantly from a
 * cold/killed process, without waiting for a Dart engine to spin up.
 */
class AlarmActivity : Activity() {

    private var doses: List<AlarmService.Due> = emptyList()

    /** Set in onCreate from SnoozePrefs; the label and the snooze use the same value. */
    private var snoozeMinutes = 10

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockscreen()

        doses = AlarmService.dosesFrom(intent.extras)

        setContentView(R.layout.activity_alarm)

        // Opened from AlarmService.notifyInstead: nothing is ringing yet. On screen, the app may start it.
        if (savedInstanceState == null && intent.getBooleanExtra(AlarmService.EXTRA_RING_ON_OPEN, false)) {
            runCatching {
                // Every listed dose: doses due together share the fallback notification.
                for (dose in doses) {
                    androidx.core.content.ContextCompat.startForegroundService(
                        this,
                        Intent(this, AlarmService::class.java).apply {
                            action = AlarmService.ACTION_RING
                            putExtra(AlarmScheduler.EXTRA_DOSE_ID, dose.id)
                            putExtra(AlarmScheduler.EXTRA_MED_NAME, dose.name)
                            putExtra(AlarmScheduler.EXTRA_DOSAGE, dose.dosage)
                        },
                    )
                }
            }.onFailure {
                // The insistent notification keeps ringing until Taken/Snooze, so this isn't silent.
                android.util.Log.e("DoseKeeper/Activity", "couldn't start ringing from the alarm screen", it)
            }
        }

        val one = doses.singleOrNull()
        findViewById<android.widget.TextView>(R.id.alarm_med_name).apply {
            if (one != null) {
                text = one.name
            } else { // several due at once: one line each, smaller so they fit
                text = doses.joinToString("\n") { it.label }
                textSize = 26f
            }
        }
        findViewById<android.widget.TextView>(R.id.alarm_dosage).apply {
            text = one?.dosage.orEmpty()
            visibility = if (text.isBlank()) android.view.View.GONE else android.view.View.VISIBLE
        }

        findViewById<android.widget.Button>(R.id.alarm_taken).setOnClickListener {
            finishWith(PendingAction.TAKEN)
        }
        findViewById<android.widget.Button>(R.id.alarm_snooze).apply {
            // Read here, once, so the label and the actual snooze length can't disagree.
            snoozeMinutes = SnoozePrefs.snoozeMinutes(this@AlarmActivity)
            text = "SNOOZE $snoozeMinutes MIN"
            setOnClickListener { finishWith(PendingAction.SNOOZE) }
        }
    }

    private fun showOverLockscreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            (getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager)
                .requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
            )
        }
    }

    /**
     * Records the outcome for Dart to pick up, stops the ringing, and closes.
     * Written to SharedPreferences rather than pushed over a MethodChannel because the
     * Flutter engine may not be running at all when the alarm fires.
     */
    private fun finishWith(action: PendingAction) {
        val now = System.currentTimeMillis()
        if (action == PendingAction.SNOOZE) {
            val snoozeMs = snoozeMinutes * 60 * 1000L
            val snoozed = doses.filter {
                AlarmScheduler.schedule(this, it.id, now + snoozeMs, it.name, it.dosage)
            }
            // Android refused a snooze alarm. Stopping now would mean that dose never rings
            // again, so keep ringing and say so. Undo the snoozes that did arm: tapping Taken
            // next would otherwise ring them again minutes from now.
            if (snoozed.size < doses.size) {
                snoozed.forEach { AlarmScheduler.disarm(this, it.id) }
                Toast.makeText(this, "Couldn't snooze. Take it now, or try again.", Toast.LENGTH_LONG).show()
                return
            }
        }

        val prefs = getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE).edit()
        for (dose in doses) {
            prefs.putString("pending_action_${dose.id}", action.name)
                .putLong("pending_action_at_${dose.id}", now)
        }
        prefs.apply()

        AlarmService.stop(this, doses.map { it.id }.toLongArray())
        finish()
    }

    /** The back button must not dismiss a medication alarm. */
    @Deprecated("Intentional: an alarm you can back out of is an alarm you can miss.")
    override fun onBackPressed() {
        // no-op
    }

    enum class PendingAction { TAKEN, SNOOZE }
}
