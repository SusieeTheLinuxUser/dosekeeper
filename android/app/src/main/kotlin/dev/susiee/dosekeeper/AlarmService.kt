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
import android.os.IBinder
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
                start()
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
        private const val RING_TIMEOUT_MS = 5 * 60 * 1000L
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
                    putExtra(EXTRA_DOSE_IDS, doses.map { it.id }.toLongArray())
                    putExtra(EXTRA_MED_NAMES, doses.map { it.name }.toTypedArray())
                    putExtra(EXTRA_DOSAGES, doses.map { it.dosage }.toTypedArray())
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

        /**
         * For when Android won't start this service: on Android 12 the inexact fallback alarm
         * (no "Alarms & reminders" access) gives no right to start one from the background.
         * Shows the alarm screen instead, which starts the ringing once it's open (allowed then).
         * Until then (unlocked phone: only a heads-up), the notification itself rings, on repeat.
         */
        fun notifyInstead(context: Context, doseId: Long, medName: String, dosage: String) {
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
            val n = buildNotification(context, listOf(Due(doseId, medName, dosage)), ringOnOpen = true, channel = FALLBACK_CHANNEL_ID)
            n.extras.putLong(AlarmScheduler.EXTRA_DOSE_ID, doseId) // see cancelFallback
            n.flags = n.flags or Notification.FLAG_INSISTENT // repeat the sound until it's dealt with
            // Same id as the service's: when the alarm screen starts the ringing, that replaces this.
            nm.notify(NOTIFICATION_ID, n)
        }

        /** The dose was dealt with elsewhere (Today screen): stop it ringing, service or fallback. */
        fun cancelFallback(context: Context, doseId: Long) {
            // Marked taken on Today while the service rings for it: without this it kept ringing.
            if (doseId in ringing) {
                context.startService(Intent(context, AlarmService::class.java).apply {
                    action = ACTION_STOP
                    putExtra(EXTRA_DOSE_IDS, longArrayOf(doseId))
                })
            }
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // One id for every dose, so check it's this dose's before clearing it.
            if (nm.activeNotifications.any {
                    it.id == NOTIFICATION_ID && it.notification.extras.getLong(AlarmScheduler.EXTRA_DOSE_ID, -1L) == doseId
                }
            ) {
                nm.cancel(NOTIFICATION_ID)
            }
        }

        /** [doseIds]: the doses the alarm screen dealt with; one that came due since keeps ringing. */
        fun stop(context: Context, doseIds: LongArray) {
            // Posted by notifyInstead when the service never started, so stopping it won't clear it.
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFICATION_ID)
            context.startService(Intent(context, AlarmService::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_DOSE_IDS, doseIds)
            })
        }
    }
}
