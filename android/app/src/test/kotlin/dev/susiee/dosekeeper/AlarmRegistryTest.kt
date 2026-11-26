package dev.susiee.dosekeeper

import android.app.AlarmManager
import android.content.Context
import android.os.UserManager
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The armed-alarm registry (AlarmScheduler) that BootReceiver re-arms from after a restart.
 * It must live in device-protected storage, so it can be read before the first unlock,
 * and must match what's actually armed.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AlarmRegistryTest {
    private val registryName = "dosekeeper_armed_alarms"
    private lateinit var context: Context
    private lateinit var alarms: AlarmManager

    @Before fun setUp() {
        context = RuntimeEnvironment.getApplication()
        alarms = context.getSystemService(AlarmManager::class.java)
        DeviceStorage.migrated.clear() // process-wide; a fresh install-update each test
    }

    private fun deviceRegistry() =
        context.createDeviceProtectedStorageContext().getSharedPreferences(registryName, 0)

    private fun entry(id: Long) = JSONObject(deviceRegistry().getString(id.toString(), null)!!)

    private fun prefsFile(c: Context, name: String) = java.io.File(c.dataDir, "shared_prefs/$name.xml")

    /** What's armed: dose alarm trigger times (setAlarmClock). */
    private fun armed() = shadowOf(alarms).scheduledAlarms.map { it.triggerAtTime }.sorted()

    /** A restart: Android drops every alarm, the registry file stays. */
    private fun reboot() = shadowOf(alarms).scheduledAlarms.forEach { alarms.cancel(it.operation!!) }

    @Test fun storageIsReallySeparate() {
        assertNotEquals(
            prefsFile(context, registryName),
            prefsFile(context.createDeviceProtectedStorageContext(), registryName),
        )
    }

    @Test fun scheduleWritesOnlyTheLabelAndTimeToDeviceStorage() {
        val at = System.currentTimeMillis() + 60_000
        assertTrue(AlarmScheduler.schedule(context, 11, at, "Med", "1 pill"))

        assertEquals(at, entry(11).getLong("triggerAt"))
        assertEquals("Med", entry(11).getString("medName"))
        assertEquals("1 pill", entry(11).getString("dosage"))
        // Readable before unlock: nothing beyond what ringing needs.
        assertEquals(setOf("triggerAt", "medName", "dosage"), entry(11).keys().asSequence().toSet())
        assertFalse(context.getSharedPreferences(registryName, 0).contains("11"))
        assertEquals(listOf(at), armed())
    }

    @Test fun registryFollowsRescheduleCancelAndFire() {
        val now = System.currentTimeMillis()
        AlarmScheduler.schedule(context, 12, now + 1_000_000, "A", "")
        AlarmScheduler.schedule(context, 12, now + 2_000_000, "B", "2") // edited: same dose, new time
        assertEquals(now + 2_000_000, entry(12).getLong("triggerAt"))
        assertEquals(listOf(now + 2_000_000), armed())

        AlarmScheduler.disarm(context, 12)
        assertFalse(deviceRegistry().contains("12"))
        assertEquals(emptyList<Long>(), armed())

        AlarmScheduler.schedule(context, 13, now + 3_000_000, "C", "")
        AlarmScheduler.forget(context, 13) // AlarmReceiver: it fired
        assertFalse(deviceRegistry().contains("13"))
    }

    @Test fun rearmAfterRebootRingsLateDosesAndDropsMissedOnes() {
        val now = System.currentTimeMillis()
        AlarmScheduler.schedule(context, 1, now + 60_000, "Future", "")
        AlarmScheduler.schedule(context, 2, now - 60_000, "Late", "") // due while the phone was off
        AlarmScheduler.schedule(context, 3, now - 2 * 60 * 60 * 1000L - 60_000, "Missed", "") // > 2 h
        reboot()
        assertEquals(emptyList<Long>(), armed())

        AlarmScheduler.rearmAll(context, now)

        assertEquals(listOf(now + 10_000, now + 60_000), armed())
        assertEquals(now + 10_000, entry(2).getLong("triggerAt"))
        assertFalse(deviceRegistry().contains("3"))
    }

    @Test fun rearmWorksBeforeTheFirstUnlock() {
        val now = System.currentTimeMillis()
        AlarmScheduler.schedule(context, 88, now + 60_000, "M", "")
        reboot()
        shadowOf(context.getSystemService(UserManager::class.java)).setUserUnlocked(false)
        assertFalse(DeviceStorage.isUnlocked(context))

        AlarmScheduler.rearmAll(context, now)

        assertEquals(listOf(now + 60_000), armed())
    }

    @Test fun existingInstallsKeepTheirData() {
        val name = "migration_test_prefs" // its own name: DeviceStorage migrates each name once
        context.getSharedPreferences(name, 0).edit().putString("77", "{\"triggerAt\":123}").commit()

        assertTrue(DeviceStorage.prefs(context, name).contains("77"))
        assertFalse(prefsFile(context, name).exists())
    }

    @Test fun firstUseMovesEveryFileTogether() {
        context.getSharedPreferences(BootReceiver.PREFS, 0).edit().putString("pending_action_5", "TAKEN").commit()
        context.getSharedPreferences("dosekeeper_settings", 0).edit().putInt("snooze_minutes", 15).commit()

        DeviceStorage.prefs(context, "dosekeeper_armed_alarms") // the update's re-arm

        assertFalse(prefsFile(context, BootReceiver.PREFS).exists())
        assertEquals(15, SnoozePrefs.snoozeMinutes(context))
        assertEquals("TAKEN", DeviceStorage.prefs(context, BootReceiver.PREFS).getString("pending_action_5", null))
    }

    @Test fun aLaterProcessNeverMovesAnOldFileOverNewerData() {
        DeviceStorage.prefs(context, BootReceiver.PREFS) // first run after the update: moved
        DeviceStorage.prefs(context, BootReceiver.PREFS).edit().putString("pending_action_9", "TAKEN").commit()
        // An old file left behind (a move that failed), then a new process.
        context.getSharedPreferences(BootReceiver.PREFS, 0).edit().putString("stale", "x").commit()
        DeviceStorage.migrated.clear()

        val prefs = DeviceStorage.prefs(context, BootReceiver.PREFS)

        assertEquals("TAKEN", prefs.getString("pending_action_9", null))
        assertFalse(prefs.contains("stale"))
    }

    @Test fun noMigrationWhileLocked() {
        val name = "migration_locked_test_prefs"
        context.getSharedPreferences(name, 0).edit().putString("k", "v").commit()
        val um = shadowOf(context.getSystemService(UserManager::class.java))

        um.setUserUnlocked(false)
        assertFalse(DeviceStorage.prefs(context, name).contains("k"))
        assertTrue(prefsFile(context, name).exists())

        um.setUserUnlocked(true) // retried at the next call once unlocked
        assertTrue(DeviceStorage.prefs(context, name).contains("k"))
    }
}
