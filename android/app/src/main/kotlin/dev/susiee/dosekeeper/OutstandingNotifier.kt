package dev.susiee.dosekeeper

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * A quiet, ongoing notification for doses that are overdue. Separate from AlarmService's
 * ringing notification: this one has no sound and doesn't take over the screen, so a missed
 * dose stays visible after the alarm itself has been silenced or ignored.
 *
 * Swiping it away discards the doses it listed: they stay missed in the history, but never
 * bring the notification back. Without that it was re-posted on every app open, for days,
 * for doses too old to appear on the Today screen and so impossible to clear any other way.
 */
object OutstandingNotifier {
    private const val CHANNEL_ID = "outstanding_doses"
    private const val NOTIFICATION_ID = 4243
    const val KEY_DISMISSED_THROUGH = "outstanding_dismissed_through"

    /** [shownAt] is the moment the listed doses were worked out, so a swipe discards only those. */
    fun show(context: Context, title: String, text: String, shownAt: Long) {
        createChannel(context)

        val openApp = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // Fires on a user swipe or "clear all", never on our own cancel(). Unique data per
        // update: otherwise this one PendingIntent changes just before the notification
        // does, and a swipe in that gap would discard doses the user never saw listed.
        val dismissed = PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, OutstandingDismissedReceiver::class.java)
                .setData(Uri.parse("dosekeeper://outstanding/$shownAt"))
                .putExtra(KEY_DISMISSED_THROUGH, shownAt),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(false)
            .setContentIntent(openApp)
            .setDeleteIntent(dismissed)
            .build()

        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, notification)
    }

    fun clear(context: Context) {
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(NOTIFICATION_ID)
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Missed doses",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Stays until an overdue dose is marked taken or skipped, or it's swiped away."
            setSound(null, null)
            enableVibration(false)
        }
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }
}

/** Remembers what the user discarded, for the next sync -- the app may not be running now. */
class OutstandingDismissedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val through = intent.getLongExtra(OutstandingNotifier.KEY_DISMISSED_THROUGH, 0L)
        context.getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong(OutstandingNotifier.KEY_DISMISSED_THROUGH, through)
            .apply()
    }
}
