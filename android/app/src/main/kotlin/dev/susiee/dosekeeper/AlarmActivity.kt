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

    private var doseId: Long = -1L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockscreen()

        doseId = intent.getLongExtra(AlarmScheduler.EXTRA_DOSE_ID, -1L)
        val medName = intent.getStringExtra(AlarmScheduler.EXTRA_MED_NAME) ?: "Medication"
        val dosage = intent.getStringExtra(AlarmScheduler.EXTRA_DOSAGE) ?: ""

        setContentView(R.layout.activity_alarm)

        // Opened from AlarmService.notifyInstead: nothing is ringing yet. On screen, the app may start it.
        if (savedInstanceState == null && intent.getBooleanExtra(AlarmService.EXTRA_RING_ON_OPEN, false)) {
            runCatching {
                androidx.core.content.ContextCompat.startForegroundService(
                    this,
                    Intent(this, AlarmService::class.java).apply {
                        action = AlarmService.ACTION_RING
                        putExtras(intent)
                    },
                )
            }.onFailure {
                // The insistent notification keeps ringing until Taken/Snooze, so this isn't silent.
                android.util.Log.e("DoseKeeper/Activity", "couldn't start ringing from the alarm screen", it)
            }
        }

        findViewById<android.widget.TextView>(R.id.alarm_med_name).text = medName
        findViewById<android.widget.TextView>(R.id.alarm_dosage).apply {
            text = dosage
            visibility = if (dosage.isBlank()) android.view.View.GONE else android.view.View.VISIBLE
        }

        findViewById<android.widget.Button>(R.id.alarm_taken).setOnClickListener {
            finishWith(PendingAction.TAKEN)
        }
        findViewById<android.widget.Button>(R.id.alarm_snooze).setOnClickListener {
            finishWith(PendingAction.SNOOZE)
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
        if (action == PendingAction.SNOOZE) {
            val medName = intent.getStringExtra(AlarmScheduler.EXTRA_MED_NAME) ?: "Medication"
            val dosage = intent.getStringExtra(AlarmScheduler.EXTRA_DOSAGE) ?: ""
            val snoozed = AlarmScheduler.schedule(
                this,
                doseId,
                System.currentTimeMillis() + SNOOZE_MS,
                medName,
                dosage,
            )
            // Android refused the snooze alarm. Stopping now would mean this dose never
            // rings again, so keep ringing and say so.
            if (!snoozed) {
                Toast.makeText(this, "Couldn't snooze. Take it now, or try again.", Toast.LENGTH_LONG).show()
                return
            }
        }

        getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString("pending_action_$doseId", action.name)
            .putLong("pending_action_at_$doseId", System.currentTimeMillis())
            .apply()

        AlarmService.stop(this)
        finish()
    }

    /** The back button must not dismiss a medication alarm. */
    @Deprecated("Intentional: an alarm you can back out of is an alarm you can miss.")
    override fun onBackPressed() {
        // no-op
    }

    enum class PendingAction { TAKEN, SNOOZE }

    companion object {
        private const val SNOOZE_MS = 10 * 60 * 1000L
    }
}
