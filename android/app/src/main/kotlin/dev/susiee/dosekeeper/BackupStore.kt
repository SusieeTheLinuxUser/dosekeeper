package dev.susiee.dosekeeper

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
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
    private const val KEY_LAST_BACKUP_AT = "last_backup_at"
    private const val MIME_JSON = "application/json"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Takes a lasting grant on [tree] (survives reboots) and makes it the backup folder. */
    fun setFolder(context: Context, tree: Uri) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        context.contentResolver.takePersistableUriPermission(tree, flags)
        // Let go of the previous folder's grant: Android caps how many an app may hold.
        folderUri(context)?.takeIf { it != tree }?.let {
            runCatching { context.contentResolver.releasePersistableUriPermission(it, flags) }
        }
        prefs(context).edit().putString(KEY_TREE_URI, tree.toString()).apply()
    }

    /**
     * The backup folder, or null if none was chosen or the grant is gone (revoked in
     * settings, or the folder was deleted) -- the caller must treat that as "backups
     * are off", not as silently succeeding.
     */
    fun folderUri(context: Context): Uri? {
        val stored = prefs(context).getString(KEY_TREE_URI, null) ?: return null
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

    private fun requireFolder(context: Context): Uri =
        folderUri(context) ?: throw FileNotFoundException("No backup folder chosen")

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

    fun list(context: Context): List<String> =
        children(context, requireFolder(context)).map { it.second }

    fun read(context: Context, name: String): String {
        val tree = requireFolder(context)
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
     * Writes [content] as [name], replacing that file if it exists. Opened with "wt"
     * (truncate): plain "w" does not truncate on every provider, and a shorter backup
     * written over a longer one would leave trailing garbage -- a corrupt backup that
     * only shows up on the day it's needed.
     */
    fun write(context: Context, name: String, content: String) {
        val tree = requireFolder(context)
        val bytes = content.toByteArray(Charsets.UTF_8)
        val existing = find(context, tree, name)
        val written = existing != null && runCatching { writeTo(context, existing, "wt", bytes) }.isSuccess
        if (!written) {
            // No file yet, or this provider refuses "wt": start from a fresh, empty file.
            existing?.let { DocumentsContract.deleteDocument(context.contentResolver, it) }
            val parent = DocumentsContract.buildDocumentUriUsingTree(
                tree,
                DocumentsContract.getTreeDocumentId(tree),
            )
            val created = DocumentsContract.createDocument(context.contentResolver, parent, MIME_JSON, name)
                ?: throw FileNotFoundException("Could not create $name")
            writeTo(context, created, "w", bytes)
        }
        prefs(context).edit().putLong(KEY_LAST_BACKUP_AT, System.currentTimeMillis()).apply()
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
