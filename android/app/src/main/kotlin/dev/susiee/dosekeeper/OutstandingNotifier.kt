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
    const val EXTRA_ACTION = "outstanding_action"
    const val ACTION_TAKEN = "TAKEN" // the strings Dart's drainPendingActions expects
    const val ACTION_SKIPPED = "SKIPPED"
    private const val REQ_TAKEN = 1
    private const val REQ_SKIPPED = 2

    /**
     * [shownAt] is the moment the listed doses were worked out, so a swipe discards only those.
     * [doseId] is set only when the notification covers exactly one dose -- it then gets
     * Taken/Skip buttons. With several, one tap resolving them all is too easy to get
     * wrong for medication, so the tap just opens the app as before.
     */
    fun show(context: Context, title: String, text: String, shownAt: Long, doseId: Long? = null) {
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

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(false)
            .setContentIntent(openApp)
            .setDeleteIntent(dismissed)

        if (doseId != null) {
            builder.addAction(resolveAction(context, doseId, ACTION_TAKEN, "Taken", REQ_TAKEN))
            builder.addAction(resolveAction(context, doseId, ACTION_SKIPPED, "Skip", REQ_SKIPPED))
        }

        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, builder.build())
    }

    // Distinct request codes and data per action, or Taken and Skip share one PendingIntent.
    private fun resolveAction(
        context: Context,
        doseId: Long,
        action: String,
        label: String,
        requestCode: Int,
    ): NotificationCompat.Action {
        val tapped = PendingIntent.getBroadcast(
            context,
            requestCode,
            Intent(context, OutstandingActionReceiver::class.java)
                .setData(Uri.parse("dosekeeper://outstanding/$doseId/$action"))
                .putExtra(AlarmScheduler.EXTRA_DOSE_ID, doseId)
                .putExtra(EXTRA_ACTION, action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Action.Builder(null, label, tapped).build()
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

/**
 * Taken/Skip tapped on the missed-dose notification. A receiver, not an activity, so the
 * screen stays where it is (this must work from the lockscreen). Records the outcome in
 * the same SharedPreferences record the alarm screen writes and Dart already drains --
 * no second outcome store. Dart may not be running now; the next sync applies it.
 */
class OutstandingActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val doseId = intent.getLongExtra(AlarmScheduler.EXTRA_DOSE_ID, -1L)
        val action = intent.getStringExtra(OutstandingNotifier.EXTRA_ACTION)
        if (doseId < 0 ||
            (action != OutstandingNotifier.ACTION_TAKEN && action != OutstandingNotifier.ACTION_SKIPPED)
        ) {
            return
        }
        context.getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString("pending_action_$doseId", action)
            .putLong("pending_action_at_$doseId", System.currentTimeMillis())
            .apply()
        // Anything still armed or ringing for the dose -- e.g. a snooze alarm set before
        // it became missed -- must not ring for a dose that's now resolved.
        AlarmScheduler.cancel(context, doseId)
        OutstandingNotifier.clear(context)
    }
}
