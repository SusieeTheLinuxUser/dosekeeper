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
