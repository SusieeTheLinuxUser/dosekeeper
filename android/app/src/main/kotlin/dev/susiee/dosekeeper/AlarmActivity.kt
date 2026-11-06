package dev.susiee.dosekeeper

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager

/**
 * The ringing alarm screen. Appears over the lockscreen with the screen turned on.
 *
 * Deliberately NOT the Flutter activity: this must be able to show instantly from a
 * cold/killed process, without waiting for a Dart engine to spin up.
 */
class AlarmActivity : Activity() {

    private var doses: List<AlarmService.Due> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockscreen()

        val ids = intent.getLongArrayExtra(AlarmService.EXTRA_DOSE_IDS) ?: LongArray(0)
        val names = intent.getStringArrayExtra(AlarmService.EXTRA_MED_NAMES)
        val dosages = intent.getStringArrayExtra(AlarmService.EXTRA_DOSAGES)
        doses = ids.mapIndexed { i, id ->
            AlarmService.Due(id, names?.getOrNull(i) ?: "Medication", dosages?.getOrNull(i) ?: "")
        }

        setContentView(R.layout.activity_alarm)

        // Opened from AlarmService.notifyInstead: nothing is ringing yet. On screen, the app may start it.
        if (savedInstanceState == null && intent.getBooleanExtra(AlarmService.EXTRA_RING_ON_OPEN, false)) {
            runCatching {
                androidx.core.content.ContextCompat.startForegroundService(
                    this,
                    Intent(this, AlarmService::class.java).apply {
                        action = AlarmService.ACTION_RING
                        doses.firstOrNull()?.let { // the fallback is always one dose
                            putExtra(AlarmScheduler.EXTRA_DOSE_ID, it.id)
                            putExtra(AlarmScheduler.EXTRA_MED_NAME, it.name)
                            putExtra(AlarmScheduler.EXTRA_DOSAGE, it.dosage)
                        }
                    },
                )
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
        val now = System.currentTimeMillis()
        val prefs = getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE).edit()
        for (dose in doses) {
            prefs.putString("pending_action_${dose.id}", action.name)
                .putLong("pending_action_at_${dose.id}", now)
        }
        prefs.apply()

        if (action == PendingAction.SNOOZE) {
            for (dose in doses) {
                AlarmScheduler.schedule(this, dose.id, now + SNOOZE_MS, dose.name, dose.dosage)
            }
        }

        AlarmService.stop(this, doses.map { it.id }.toLongArray())
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
