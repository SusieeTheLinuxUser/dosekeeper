package dev.susiee.dosekeeper

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs the same Dart DoseScheduler.sync() the app runs when open, but from a headless
 * FlutterEngine started by Android triggers: an alarm firing, a time/time-zone change,
 * a daily safety net, a reboot. Dart owns the schedule and the database, so the
 * scheduling rules are NOT ported to Kotlin -- this only gives Dart a chance to run
 * without the user opening the app. Without it, alarms (armed [DoseScheduler.horizon]
 * = 3 days ahead) simply stop if the app isn't opened for 3 days, and stay on the old
 * wall-clock time after a time-zone change.
 *
 * Main thread only: every field is touched from the main looper.
 */
object BackgroundSync {
    private const val TAG = "DoseKeeper/BgSync"

    /** BroadcastReceiver.goAsync() allows ~10s (foreground broadcasts); finish before. */
    private const val PENDING_TIMEOUT_MS = 9_000L

    /** A stuck Dart must never block later syncs. */
    private const val RUN_TIMEOUT_MS = 60_000L

    const val ACTION_DAILY_SYNC = "dev.susiee.dosekeeper.DAILY_SYNC"

    private val handler = Handler(Looper.getMainLooper())
    private val pendings = mutableListOf<BroadcastReceiver.PendingResult>()
    private var engine: FlutterEngine? = null
    private var running = false
    private var again = false
    private var timeout: Runnable? = null
    private var ctx: Context? = null

    /**
     * Asks for a background sync, finishing [pending] (from goAsync(), if any) within
     * the broadcast limit no matter how the run goes. [delayMs] delays the engine start,
     * e.g. so a ringing alarm always goes first.
     */
    fun request(context: Context, pending: BroadcastReceiver.PendingResult? = null, delayMs: Long = 0) {
        val ctx = context.applicationContext
        armSafetyNet(ctx) // first: nothing below may get a chance to fail before this
        if (pending != null) {
            pendings.add(pending)
            // TIME_SET/TIMEZONE_CHANGED are foreground broadcasts with a 10 s limit: never
            // let a long sync keep the process alive on this broadcast's tab.
            handler.postDelayed({
                if (pendings.remove(pending)) pending.finish()
            }, PENDING_TIMEOUT_MS)
        }
        handler.postDelayed({
            if (running) {
                // A run is in progress and may have read the old clock; rerun after it.
                again = true
            } else {
                start(ctx)
            }
        }, delayMs)
    }

    private fun start(ctx: Context) {
        running = true // before the async load, so a second request can't start a second engine
        val t = Runnable {
            Log.e(TAG, "background sync timed out; forcing the run to finish")
            finish()
        }
        timeout = t
        handler.postDelayed(t, RUN_TIMEOUT_MS)
        this.ctx = ctx
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(ctx)
            // The engine only after this: FlutterEngine() would otherwise load Flutter
            // synchronously, on the main thread a ringing alarm needs.
            loader.ensureInitializationCompleteAsync(ctx, null, handler) {
                if (timeout === t) launch(ctx, loader.findAppBundlePath()) // else timed out already
            }
        } catch (e: Exception) {
            Log.e(TAG, "couldn't start the background sync engine", e)
            finish()
        }
    }

    private fun launch(ctx: Context, bundlePath: String) {
        try {
            val e = FlutterEngine(ctx) // plugins auto-register; sqflite needs that
            engine = e
            MethodChannel(e.dartExecutor.binaryMessenger, "dev.susiee.dosekeeper/alarms")
                .setMethodCallHandler { call, result ->
                    if (call.method == "backgroundSyncDone") {
                        result.success(true)
                        // Posted: not from inside the engine's own callback. Checked: if the
                        // timeout got in first, this must not end a rerun started since.
                        handler.post { if (engine === e) finish() }
                    } else if (!AlarmChannel.handle(ctx, call, result)) {
                        result.notImplemented()
                    }
                }
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(bundlePath, "backgroundSync"),
            )
        } catch (e: Exception) {
            Log.e(TAG, "couldn't start the background sync engine", e)
            finish()
        }
    }

    /** Tears the run down: engine, timeout, and every pending broadcast result. */
    private fun finish() {
        engine?.destroy()
        engine = null
        running = false
        timeout?.let { handler.removeCallbacks(it) }
        timeout = null
        pendings.forEach { it.finish() }
        pendings.clear()
        if (again) {
            again = false
            // Rerun once. The triggering broadcasts' pending results are already
            // finished, so the rerun needs no goAsync bookkeeping.
            ctx?.let { start(it) }
        }
    }

    /**
     * Tops the armed alarms up at least daily even when nothing else fires. A
     * weekly-only medication can have no alarm for days, so no alarm fires to trigger
     * a sync; inexact needs no permission, and is deliberately not setAlarmClock (that
     * would show the user a fake next alarm). Worst case Android stretches it to
     * ~42 h, still inside the 72 h horizon.
     */
    fun armSafetyNet(context: Context) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = PendingIntent.getBroadcast(
                context,
                4245,
                Intent(context, BootReceiver::class.java).setAction(ACTION_DAILY_SYNC),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            am.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                System.currentTimeMillis() + 24 * 60 * 60 * 1000L,
                pi,
            )
        } catch (e: RuntimeException) {
            Log.e(TAG, "couldn't arm the daily sync safety net", e)
        }
    }
}
