package dev.susiee.dosekeeper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Rings the alarm and keeps ringing until the user acknowledges it.
 *
 * Runs as a foreground service so the OS will not silently reclaim it mid-ring, plays
 * through the ALARM stream (so it is audible even on silent/vibrate), and posts a
 * full-screen-intent notification so the alarm UI takes over the screen even on lockscreen.
 */
class AlarmService : Service() {

    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var rampHandler: Handler? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_RING -> startRinging(intent)
            ACTION_STOP -> {
                val handled = intent.getLongArrayExtra(EXTRA_DOSE_IDS)
                if (handled == null) ringing.clear() else handled.forEach { ringing.remove(it) }
                if (ringing.isEmpty()) { stopSelf(); return START_NOT_STICKY }
                // Another dose came due while the alarm screen was open: keep ringing for it.
                startForeground(NOTIFICATION_ID, buildNotification(this, ringing.values.toList()))
            }
        }
        // START_REDELIVER_INTENT: if the process is killed mid-ring, come back ringing.
        return START_REDELIVER_INTENT
    }

    private fun startRinging(intent: Intent) {
        val doseId = intent.getLongExtra(AlarmScheduler.EXTRA_DOSE_ID, -1L)
        val medName = intent.getStringExtra(AlarmScheduler.EXTRA_MED_NAME) ?: "Medication"
        val dosage = intent.getStringExtra(AlarmScheduler.EXTRA_DOSAGE) ?: ""

        Log.i(TAG, "ringing dose=$doseId med=$medName")

        // Two doses due at the same instant each call this once. Both stay listed, so the
        // alarm screen shows both: it used to show only the latest, and the other dose
        // never got a screen of its own. Without releasing the previous ring's
        // player/vibrator/wakelock first, the old MediaPlayer would keep looping, orphaned.
        ringing[doseId] = Due(doseId, medName, dosage)
        releaseRingingResources()
        acquireWakeLock()
        createChannel(this)
        startForeground(NOTIFICATION_ID, buildNotification(this, ringing.values.toList()))
        playAlarmSound()
        startVibrating()
    }

    private fun acquireWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        @Suppress("DEPRECATION")
        wakeLock = pm.newWakeLock(
            PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "DoseKeeper::AlarmWakeLock",
        ).apply { acquire(RING_TIMEOUT_MS) }
    }

    private fun playAlarmSound() {
        try {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            // Assigned before it's set up, so a failure below (bad ringtone URI, prepare()
            // throwing) still leaves it where releaseRingingResources() will free it.
            player = MediaPlayer()
            player?.apply {
                setDataSource(this@AlarmService, uri)
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                isLooping = true
                prepare()
                // Quiet before start(), so not even the first moment plays at full volume.
                val ramp = SnoozePrefs.volumeRamp(this@AlarmService)
                if (ramp) setVolume(RAMP_START_VOLUME, RAMP_START_VOLUME)
                start()
                if (ramp) startVolumeRamp(this)
            }
            // Make sure the alarm stream is actually audible.
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (am.getStreamVolume(AudioManager.STREAM_ALARM) == 0) {
                am.setStreamVolume(
                    AudioManager.STREAM_ALARM,
                    (am.getStreamMaxVolume(AudioManager.STREAM_ALARM) * 0.7).toInt().coerceAtLeast(1),
                    0,
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "failed to play alarm sound", e)
        }
    }

    /**
     * Opt-in ("Gradually louder alarm" on the Info page): step the volume up evenly from
     * RAMP_START_VOLUME to full over 30s, then leave it at full. For heavy sleepers a
     * flat blast doesn't wake. setVolume only scales this player against the alarm
     * stream's volume; the stream volume itself is never touched.
     */
    private fun startVolumeRamp(p: MediaPlayer) {
        val handler = Handler(Looper.getMainLooper()).also { rampHandler = it }
        var step = 0
        val tick = object : Runnable {
            override fun run() {
                // releaseRingingResources() cancels these callbacks; the identity check
                // covers any post that was already queued, so a released or replaced
                // player is never touched.
                if (player !== p) return
                step++
                if (step >= RAMP_STEPS) {
                    p.setVolume(1f, 1f)
                    rampHandler = null
                    return
                }
                val v = RAMP_START_VOLUME + (1f - RAMP_START_VOLUME) * step / RAMP_STEPS
                p.setVolume(v, v)
                handler.postDelayed(this, RAMP_STEP_MS)
            }
        }
        handler.postDelayed(tick, RAMP_STEP_MS)
    }

    private fun startVibrating() {
        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        val pattern = longArrayOf(0, 800, 600)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
        } else {
            @Suppress("DEPRECATION")
            vibrator?.vibrate(pattern, 0)
        }
    }

    override fun onDestroy() {
        ringing.clear()
        releaseRingingResources()
        super.onDestroy()
    }

    private fun releaseRingingResources() {
        // Cancel the volume ramp first: its callbacks must never touch the player below
        // once it's released (this runs on a re-ring too, before the new player starts).
        rampHandler?.removeCallbacksAndMessages(null)
        rampHandler = null
        // stop() throws if the player never started (e.g. prepare() failed). release()
        // must still run, or the native player leaks for the life of the process.
        player?.let { p ->
            runCatching { p.stop() }
            p.release()
        }
        player = null
        vibrator?.cancel()
        wakeLock?.takeIf { it.isHeld }?.release()
    }

    data class Due(val id: Long, val name: String, val dosage: String) {
        val label get() = if (dosage.isBlank()) name else "$name - $dosage"
    }

    companion object {
        // ponytail: in memory. If Android kills the process mid-ring, START_REDELIVER_INTENT
        // brings back only the latest dose; persist this if that ever matters.
        private val ringing = LinkedHashMap<Long, Due>()
        const val EXTRA_DOSE_IDS = "dose_ids"
        const val EXTRA_MED_NAMES = "med_names"
        const val EXTRA_DOSAGES = "dosages"
        private const val TAG = "DoseKeeper/Service"
        const val ACTION_RING = "dev.susiee.dosekeeper.RING"
        const val ACTION_STOP = "dev.susiee.dosekeeper.STOP"
        const val CHANNEL_ID = "dose_alarms"
        private const val FALLBACK_CHANNEL_ID = "dose_alarms_fallback"
        const val NOTIFICATION_ID = 4242
        // Its own id, not the service's: stopping the service removes whatever sits under
        // NOTIFICATION_ID, which took a still-unanswered fallback dose with it.
        private const val FALLBACK_NOTIFICATION_ID = 4244
        private const val RING_TIMEOUT_MS = 5 * 60 * 1000L
        private const val RAMP_START_VOLUME = 0.1f
        private const val RAMP_STEPS = 30
        private const val RAMP_STEP_MS = 1000L
        const val EXTRA_RING_ON_OPEN = "ring_on_open"

        private fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Medication alarms",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Rings when a dose is due. Do not disable."
                setSound(null, null) // the service plays the sound itself, on the alarm stream
                enableVibration(false)
                setBypassDnd(true)
                lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
            }
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }

        private fun buildNotification(
            context: Context,
            doses: List<Due>,
            ringOnOpen: Boolean = false,
            channel: String = CHANNEL_ID,
        ): Notification {
            val fullScreen = PendingIntent.getActivity(
                context,
                doses.last().id.toInt(),
                Intent(context, AlarmActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                    putExtras(dosesBundle(doses))
                    putExtra(EXTRA_RING_ON_OPEN, ringOnOpen)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            val title = doses.joinToString(", ") { it.label }
            return NotificationCompat.Builder(context, channel)
                .setSmallIcon(android.R.drawable.ic_popup_reminder)
                .setContentTitle("Time for $title")
                .setContentText("Tap to mark it taken")
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setOngoing(true)
                .setAutoCancel(false)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .build()
        }

        /** The doses as extras: the alarm screen's intent, and the fallback notification. */
        fun dosesBundle(doses: List<Due>) = Bundle().apply {
            putLongArray(EXTRA_DOSE_IDS, doses.map { it.id }.toLongArray())
            putStringArray(EXTRA_MED_NAMES, doses.map { it.name }.toTypedArray())
            putStringArray(EXTRA_DOSAGES, doses.map { it.dosage }.toTypedArray())
        }

        fun dosesFrom(extras: Bundle?): List<Due> {
            val ids = extras?.getLongArray(EXTRA_DOSE_IDS) ?: return emptyList()
            val names = extras.getStringArray(EXTRA_MED_NAMES)
            val dosages = extras.getStringArray(EXTRA_DOSAGES)
            return ids.mapIndexed { i, id ->
                Due(id, names?.getOrNull(i) ?: "Medication", dosages?.getOrNull(i) ?: "")
            }
        }

        /**
         * For when Android won't start this service: on Android 12 the inexact fallback alarm
         * (no "Alarms & reminders" access) gives no right to start one from the background.
         * Shows the alarm screen instead, which starts the ringing once it's open (allowed then).
         * Until then (unlocked phone: only a heads-up), the notification itself rings, on repeat.
         */
        fun notifyInstead(context: Context, doseId: Long, medName: String, dosage: String) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // Two doses due together each land here. Keep the ones already listed: posting
            // just this one replaced them, and an earlier dose (its alarm already fired and
            // forgotten) then never showed or rang.
            val doses = fallbackDoses(nm).apply {
                removeAll { it.id == doseId }
                add(Due(doseId, medName, dosage))
            }
            postFallback(context, doses.toList())
        }

        private fun postFallback(context: Context, doses: List<Due>) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) { // only Android 12 reaches here
                nm.createNotificationChannel(
                    NotificationChannel(FALLBACK_CHANNEL_ID, "Medication alarms (backup)", NotificationManager.IMPORTANCE_HIGH)
                        .apply {
                            description = "Rings when a dose is due and the normal alarm can't start. Do not disable."
                            setSound(
                                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                                AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_ALARM)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                    .build(),
                            )
                            enableVibration(true)
                            setBypassDnd(true)
                            lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
                        },
                )
            }
            val n = buildNotification(context, doses, ringOnOpen = true, channel = FALLBACK_CHANNEL_ID)
            n.extras.putAll(dosesBundle(doses)) // see fallbackDoses
            n.flags = n.flags or Notification.FLAG_INSISTENT // repeat the sound until it's dealt with
            // The alarm screen takes its doses off this once it has started them ringing.
            nm.notify(FALLBACK_NOTIFICATION_ID, n)
        }

        /**
         * The doses the fallback notification lists. Kept here, not only read back from the
         * notification: notify() is asynchronous, so a dose posted a moment ago (two doses
         * due together) may not be listed there yet. Read from the notification only when
         * this process hasn't posted one yet (it may have been restarted since).
         * Main thread only: receivers, the alarm screen and the method channel all run there.
         */
        private var fallback: MutableList<Due>? = null

        private fun fallbackDoses(nm: NotificationManager): MutableList<Due> =
            fallback ?: nm.activeNotifications.firstOrNull { it.id == FALLBACK_NOTIFICATION_ID }
                ?.let { dosesFrom(it.notification.extras) }.orEmpty().toMutableList()
                .also { fallback = it }

        /** The dose was dealt with elsewhere (Today, missed-dose notification): stop it ringing everywhere. */
        fun cancelFallback(context: Context, doseId: Long) {
            // Marked taken on Today while the service rings for it: without this it kept ringing.
            if (doseId in ringing) {
                context.startService(Intent(context, AlarmService::class.java).apply {
                    action = ACTION_STOP
                    putExtra(EXTRA_DOSE_IDS, longArrayOf(doseId))
                })
            }
            dropFallback(context, longArrayOf(doseId))
            // And off an alarm screen that's still open for it, or Snooze there rings it again.
            AlarmActivity.dropDoses(longArrayOf(doseId))
        }

        /**
         * Takes [doseIds] off the fallback notification: answered, or now ringing in the
         * service. One notification for every dose, so the rest stay on it, still ringing.
         */
        fun dropFallback(context: Context, doseIds: LongArray) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val listed = fallbackDoses(nm)
            if (!listed.removeAll { it.id in doseIds }) return
            if (listed.isEmpty()) nm.cancel(FALLBACK_NOTIFICATION_ID) else postFallback(context, listed.toList())
        }

        /** [doseIds]: the doses the alarm screen dealt with; one that came due since keeps ringing. */
        fun stop(context: Context, doseIds: LongArray) {
            // Posted by notifyInstead when the service never started, so stopping it won't clear it.
            dropFallback(context, doseIds)
            context.startService(Intent(context, AlarmService::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_DOSE_IDS, doseIds)
            })
        }
    }
}
