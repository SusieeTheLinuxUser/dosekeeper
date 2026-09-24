package dev.susiee.dosekeeper

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
            ACTION_STOP -> { stopSelf(); return START_NOT_STICKY }
        }
        // START_REDELIVER_INTENT: if the process is killed mid-ring, come back ringing.
        return START_REDELIVER_INTENT
    }

    private fun startRinging(intent: Intent) {
        val doseId = intent.getLongExtra(AlarmScheduler.EXTRA_DOSE_ID, -1L)
        val medName = intent.getStringExtra(AlarmScheduler.EXTRA_MED_NAME) ?: "Medication"
        val dosage = intent.getStringExtra(AlarmScheduler.EXTRA_DOSAGE) ?: ""

        Log.i(TAG, "ringing dose=$doseId med=$medName")

        // Two doses due at the same instant each call this once. Without releasing the
        // previous ring's player/vibrator/wakelock first, the old MediaPlayer keeps
        // looping forever, orphaned -- Taken/Snooze only ever stops the most recent one,
        // so the sound becomes impossible to dismiss short of force-closing the app.
        releaseRingingResources()
        acquireWakeLock()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification(doseId, medName, dosage))
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

    private fun createChannel() {
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
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(doseId: Long, medName: String, dosage: String): android.app.Notification {
        val fullScreen = PendingIntent.getActivity(
            this,
            doseId.toInt(),
            Intent(this, AlarmActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                putExtra(AlarmScheduler.EXTRA_DOSE_ID, doseId)
                putExtra(AlarmScheduler.EXTRA_MED_NAME, medName)
                putExtra(AlarmScheduler.EXTRA_DOSAGE, dosage)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val title = if (dosage.isBlank()) medName else "$medName - $dosage"
        return NotificationCompat.Builder(this, CHANNEL_ID)
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

    companion object {
        private const val TAG = "DoseKeeper/Service"
        const val ACTION_RING = "dev.susiee.dosekeeper.RING"
        const val ACTION_STOP = "dev.susiee.dosekeeper.STOP"
        const val CHANNEL_ID = "dose_alarms"
        const val NOTIFICATION_ID = 4242
        private const val RING_TIMEOUT_MS = 5 * 60 * 1000L

        fun stop(context: Context) {
            context.startService(Intent(context, AlarmService::class.java).apply {
                action = ACTION_STOP
            })
        }
    }
}
