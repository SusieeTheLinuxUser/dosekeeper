package dev.susiee.dosekeeper

import android.app.backup.BackupAgent
import android.app.backup.BackupDataInput
import android.app.backup.BackupDataOutput
import android.app.backup.FullBackupDataOutput
import android.os.ParcelFileDescriptor

/**
 * Makes Android's Google backup opt-in. The manifest's allowBackup is fixed at build time, so
 * a per-user choice has to live here: with the setting off this hands Android nothing. It
 * holds health data, so off is the default; the user's own backup folder works either way.
 */
class GoogleBackupAgent : BackupAgent() {
    override fun onFullBackup(data: FullBackupDataOutput) {
        if (BackupStore.googleBackupEnabled(this)) super.onFullBackup(data)
    }

    /**
     * Android restores data on install, before the app first runs, and doesn't restore
     * alarms. Without this no dose would ring until the app is opened. Caught so that an
     * alarm failure can't fail the restore itself: opening the app re-arms them anyway.
     */
    override fun onRestoreFinished() {
        runCatching { AlarmScheduler.rearmAll(this) }
    }

    // Key-value backup: never used, the manifest sets fullBackupOnly.
    override fun onBackup(
        oldState: ParcelFileDescriptor?,
        data: BackupDataOutput?,
        newState: ParcelFileDescriptor?,
    ) = Unit

    override fun onRestore(
        data: BackupDataInput?,
        appVersionCode: Int,
        newState: ParcelFileDescriptor?,
    ) = Unit
}
