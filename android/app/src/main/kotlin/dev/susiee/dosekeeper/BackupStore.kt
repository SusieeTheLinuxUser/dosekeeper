package dev.susiee.dosekeeper

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.File
import java.io.FileNotFoundException

/**
 * Reads and writes backup files in a folder the user picked (Storage Access Framework).
 *
 * Why a user-picked folder and not the app's own storage: everything the app owns --
 * its database, its SharedPreferences, even getExternalFilesDir() -- is deleted when
 * the app is uninstalled. That is exactly how all the user's data was lost on
 * 2026-09-24. A folder like Documents/ belongs to the user, survives an uninstall,
 * and can be copied off the phone. The only thing an uninstall takes from us here is
 * the *permission* to that folder; the files stay, and are picked again to restore.
 *
 * Deliberately needs no storage permission: SAF grants access to the one folder only.
 */
object BackupStore {
    private const val PREFS = "dosekeeper_backup"
    private const val KEY_TREE_URI = "tree_uri"
    private const val KEY_PENDING_TREE_URI = "pending_tree_uri"
    private const val KEY_LAST_BACKUP_AT = "last_backup_at"
    private const val MIME_JSON = "application/json"

    private const val GRANT_FLAGS =
        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * A file in the no-backup folder, not a preference: backups include preferences, so
     * restoring an old one could silently turn this back on after the user turned it off.
     */
    private fun googleBackupMarker(context: Context) =
        File(context.noBackupFilesDir, "google_backup_on")

    fun googleBackupEnabled(context: Context) = googleBackupMarker(context).exists()

    fun setGoogleBackupEnabled(context: Context, enabled: Boolean) {
        val marker = googleBackupMarker(context)
        if (enabled) marker.createNewFile() else marker.delete()
    }

    /**
     * Takes a lasting grant on [tree] (survives reboots) and keeps it as the *pending*
     * folder: not the backup folder until [confirmPendingFolder]. Two-phase because the
     * picker answers before Dart has asked "restore or keep" -- if answering made the
     * folder active right away, leaving the dialog unanswered (app killed, page closed)
     * would point automatic backups at a folder the user never confirmed.
     * A pending folder left over from a killed app is discarded on the next pick.
     */
    fun setPendingFolder(context: Context, tree: Uri): Map<String, Any?> {
        // Grant first: if the tree is the same as a leftover pending, the discard must
        // not release the grant we are about to rely on.
        context.contentResolver.takePersistableUriPermission(tree, GRANT_FLAGS)
        val leftover = prefs(context).getString(KEY_PENDING_TREE_URI, null)
        prefs(context).edit().putString(KEY_PENDING_TREE_URI, tree.toString()).apply()
        if (leftover != null && leftover != tree.toString()) {
            releaseGrant(context, Uri.parse(leftover))
        }
        return mapOf("folderName" to folderName(context, tree))
    }

    /** Makes the pending folder the backup folder. No-op without one. */
    fun confirmPendingFolder(context: Context) {
        val pending = prefs(context).getString(KEY_PENDING_TREE_URI, null) ?: return
        // Let go of the previous folder's grant: Android caps how many an app may hold.
        val previous = prefs(context).getString(KEY_TREE_URI, null)
        prefs(context).edit()
            .putString(KEY_TREE_URI, pending)
            .remove(KEY_PENDING_TREE_URI)
            .apply()
        if (previous != null && previous != pending) {
            releaseGrant(context, Uri.parse(previous))
        }
    }

    /** Drops the pending folder without making it active. */
    fun discardPendingFolder(context: Context) {
        val pending = prefs(context).getString(KEY_PENDING_TREE_URI, null) ?: return
        prefs(context).edit().remove(KEY_PENDING_TREE_URI).apply()
        releaseGrant(context, Uri.parse(pending))
    }

    /** Never releases the active folder's grant: pending may point at the same folder. */
    private fun releaseGrant(context: Context, uri: Uri) {
        if (uri.toString() == prefs(context).getString(KEY_TREE_URI, null)) return
        runCatching { context.contentResolver.releasePersistableUriPermission(uri, GRANT_FLAGS) }
    }

    /**
     * The backup folder (or the pending one with [pending]), or null if none was chosen
     * or the grant is gone (revoked in settings, or the folder was deleted) -- the caller
     * must treat that as "backups are off", not as silently succeeding.
     */
    fun folderUri(context: Context, pending: Boolean = false): Uri? {
        val key = if (pending) KEY_PENDING_TREE_URI else KEY_TREE_URI
        val stored = prefs(context).getString(key, null) ?: return null
        val uri = Uri.parse(stored)
        val granted = context.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isWritePermission && it.isReadPermission
        }
        return if (granted) uri else null
    }

    fun status(context: Context): Map<String, Any?> {
        val tree = folderUri(context)
        val last = prefs(context).getLong(KEY_LAST_BACKUP_AT, 0L)
        return mapOf(
            "folderName" to tree?.let { folderName(context, it) },
            "lastBackupAt" to if (last > 0L) last else null,
        )
    }

    private fun folderName(context: Context, tree: Uri): String {
        val doc = DocumentsContract.buildDocumentUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree),
        )
        val name = context.contentResolver
            .query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
        return name ?: tree.lastPathSegment ?: "Backup folder"
    }

    private fun requireFolder(context: Context, pending: Boolean = false): Uri =
        folderUri(context, pending) ?: throw FileNotFoundException(
            if (pending) "No picked folder waiting to be confirmed" else "No backup folder chosen",
        )

    /** (documentId, displayName) of every file directly inside the folder. */
    private fun children(context: Context, tree: Uri): List<Pair<String, String>> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree),
        )
        val out = mutableListOf<Pair<String, String>>()
        context.contentResolver.query(
            childrenUri,
            arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                val name = c.getString(1)
                if (id != null && name != null) out.add(id to name)
            }
        }
        return out
    }

    private fun find(context: Context, tree: Uri, name: String): Uri? =
        children(context, tree).firstOrNull { it.second == name }
            ?.let { DocumentsContract.buildDocumentUriUsingTree(tree, it.first) }

    fun list(context: Context, pending: Boolean = false): List<String> =
        children(context, requireFolder(context, pending)).map { it.second }

    fun read(context: Context, name: String, pending: Boolean = false): String {
        val tree = requireFolder(context, pending)
        val doc = find(context, tree, name) ?: throw FileNotFoundException(name)
        return readUri(context, doc)
    }

    /** Reads any document the user picked with ACTION_OPEN_DOCUMENT. */
    fun readUri(context: Context, uri: Uri): String {
        val bytes = context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Could not open the file" }
            input.readBytes()
        }
        // A real backup is kilobytes; refuse anything absurd rather than hand it on.
        require(bytes.size <= MAX_BYTES) { "File is too large to be a DoseKeeper backup" }
        return String(bytes, Charsets.UTF_8)
    }

    /**
     * Writes [content] as [name], replacing that file if it exists -- crash-safe:
     * the content goes to a fresh temp document first (`<day>.tmp.json`, which
     * Backup.isBackupFileName does not match, so it is never listed or pruned), and
     * today's existing file is deleted only once the temp is complete. The temp then
     * takes its place by rename (or copy where a provider cannot rename). Dying
     * before the delete leaves the old file untouched; dying after it leaves the
     * complete temp, which the next write installs or cleans up. A fresh empty
     * document has no stale bytes to truncate, so the old "wt"-or-recreate dance
     * (and its delete-first data-loss window) is gone entirely.
     */
    // Each channel call runs on its own thread; overlapping writes would interleave
    // their create/delete/rename steps, so one write runs at a time.
    @Synchronized
    fun write(context: Context, name: String, content: String) {
        val tree = requireFolder(context)
        val bytes = content.toByteArray(Charsets.UTF_8)
        // Ends in .json on purpose: providers append the MIME type's extension to a name
        // that lacks it, so "x.json.tmp" would be created as "x.json.tmp.json" and the
        // leftover check below would never find it.
        val tmpName = name.removeSuffix(".json") + ".tmp.json"
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree),
        )

        // A leftover temp means a previous write died. It replaces today's file only
        // when it is complete (parses) and today's file is missing or partial (a
        // death mid-copy in install); otherwise it is junk.
        find(context, tree, tmpName)?.let { leftover ->
            val dest = find(context, tree, name)
            if (!parses(context, leftover) || (dest != null && parses(context, dest))) {
                deleteOrThrow(context, leftover, tmpName)
            } else {
                dest?.let { deleteOrThrow(context, it, name) }
                if (!install(context, parent, leftover, name)) {
                    // Keep the temp: it is the only complete copy of that backup.
                    throw FileNotFoundException("An interrupted backup of $name could not be recovered")
                }
            }
        }

        val tmp = DocumentsContract.createDocument(context.contentResolver, parent, MIME_JSON, tmpName)
            ?: throw FileNotFoundException("Could not create $tmpName")
        try {
            writeTo(context, tmp, "w", bytes)
        } catch (e: Exception) {
            runCatching { DocumentsContract.deleteDocument(context.contentResolver, tmp) }
            throw e
        }
        // The new content is complete on storage; only now may today's file go away.
        find(context, tree, name)?.let { deleteOrThrow(context, it, name) }
        if (!install(context, parent, tmp, name)) {
            throw FileNotFoundException("Could not move $tmpName into place; it still holds the complete backup")
        }
        prefs(context).edit().putLong(KEY_LAST_BACKUP_AT, System.currentTimeMillis()).apply()
    }

    /**
     * Puts a complete temp document at [name] (which no file currently holds):
     * rename, or -- for providers without rename -- copy the bytes into a fresh
     * document and delete the temp. On failure nothing is left under [name].
     */
    private fun install(context: Context, parent: Uri, tmp: Uri, name: String): Boolean {
        runCatching { DocumentsContract.renameDocument(context.contentResolver, tmp, name) }
            .onSuccess { if (it != null) return true }
        val created = runCatching {
            DocumentsContract.createDocument(context.contentResolver, parent, MIME_JSON, name)
        }.getOrNull() ?: return false
        val copied = runCatching {
            val bytes = context.contentResolver.openInputStream(tmp)?.use { it.readBytes() }
                ?: throw FileNotFoundException("Could not read the temp backup")
            writeTo(context, created, "w", bytes)
        }.isSuccess
        if (!copied) {
            // Never leave a partial file under a real backup name.
            runCatching { DocumentsContract.deleteDocument(context.contentResolver, created) }
            return false
        }
        // Best effort: a surviving temp is cleaned up as stale on the next write.
        runCatching { DocumentsContract.deleteDocument(context.contentResolver, tmp) }
        return true
    }

    private fun parses(context: Context, uri: Uri) =
        runCatching { org.json.JSONObject(readUri(context, uri)) }.isSuccess

    private fun deleteOrThrow(context: Context, uri: Uri, name: String) {
        if (!DocumentsContract.deleteDocument(context.contentResolver, uri)) {
            throw FileNotFoundException("Could not remove $name")
        }
    }

    private fun writeTo(context: Context, doc: Uri, mode: String, bytes: ByteArray) {
        context.contentResolver.openOutputStream(doc, mode).use { out ->
            requireNotNull(out) { "Could not open $doc for writing" }
            out.write(bytes)
        }
    }

    fun delete(context: Context, name: String) {
        val tree = requireFolder(context)
        find(context, tree, name)?.let { DocumentsContract.deleteDocument(context.contentResolver, it) }
    }

    private const val MAX_BYTES = 20 * 1024 * 1024
}
