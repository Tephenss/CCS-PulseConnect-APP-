package com.ccspulseconnect.pulse_connect_app

import android.app.Activity
import android.content.ComponentCallbacks2
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val OFFLINE_BACKUP_CHANNEL = "pulseconnect/offline_backup"
        private const val DOCUMENT_PICKER_CHANNEL = "pulseconnect/document_picker"
        private const val DOWNLOADS_CHANNEL = "pulseconnect/downloads"
        private const val AUTO_BACKUP_FOLDER = "PulseConnect"
        private const val REQUEST_PICK_DOCUMENT = 0x5043 // 'PC'
        private const val DEFAULT_MAX_BYTES = 15L * 1024L * 1024L
        private const val DOC_PICKER_PREFS = "pulseconnect_doc_picker"
        private const val PENDING_MAX_AGE_MS = 10L * 60L * 1000L
    }

    private var pendingDocumentResult: MethodChannel.Result? = null
    private var pendingMaxBytes: Long = DEFAULT_MAX_BYTES
    private val documentCopyExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OFFLINE_BACKUP_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "writeBackupFileAuto" -> writeBackupFileAuto(call, result)
                "readBackupFileAuto" -> readBackupFileAuto(call, result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOCUMENT_PICKER_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDocument" -> pickDocument(call, result)
                "takePendingDocument" -> {
                    result.success(consumePersistedDocument())
                }
                "clearPendingDocument" -> {
                    clearPersistedDocument()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOWNLOADS_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> savePublicDownload(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun pickDocument(call: MethodCall, result: MethodChannel.Result) {
        // If the activity was killed while the system picker was open, a file may
        // already be waiting in prefs — return it instead of opening again.
        val existing = consumePersistedDocument()
        if (existing != null) {
            result.success(existing)
            return
        }

        if (pendingDocumentResult != null) {
            result.error("busy", "A file picker is already open.", null)
            return
        }

        pendingMaxBytes = when (val raw = call.argument<Any>("maxBytes")) {
            is Number -> raw.toLong().coerceAtLeast(1024L)
            else -> DEFAULT_MAX_BYTES
        }
        pendingDocumentResult = result
        markPickerInProgress(true)

        // Free GPU/UI pressure before leaving the activity — Oppo low-RAM +
        // battery saver often kills Flutter while the Documents UI is open.
        try {
            onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE)
        } catch (_: Exception) {
        }

        // ACTION_GET_CONTENT is lighter/more stable on ColorOS than
        // ACTION_OPEN_DOCUMENT + createChooser (which was black-screening).
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "application/pdf",
                    "application/msword",
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    "image/jpeg",
                    "image/png",
                    "image/webp",
                    "image/*",
                ),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        try {
            startActivityForResult(intent, REQUEST_PICK_DOCUMENT)
        } catch (e: Exception) {
            // Fallback to SAF OPEN_DOCUMENT if GET_CONTENT is blocked.
            try {
                val openDoc = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(
                        Intent.EXTRA_MIME_TYPES,
                        arrayOf(
                            "application/pdf",
                            "application/msword",
                            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                            "image/jpeg",
                            "image/png",
                            "image/webp",
                            "image/*",
                        ),
                    )
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                startActivityForResult(openDoc, REQUEST_PICK_DOCUMENT)
            } catch (e2: Exception) {
                pendingDocumentResult = null
                markPickerInProgress(false)
                result.error(
                    "picker_failed",
                    e2.message ?: e.message ?: "Unable to open file picker.",
                    null,
                )
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_PICK_DOCUMENT) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val reply = pendingDocumentResult
        pendingDocumentResult = null
        markPickerInProgress(false)

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            reply?.success(null)
            return
        }

        val uri = data.data!!
        val maxBytes = pendingMaxBytes

        // Copy off the UI thread — large PDFs on low-RAM phones otherwise freeze /
        // black-screen the activity before Flutter can resume.
        documentCopyExecutor.execute {
            try {
                val payload = copyUriToCache(uri, maxBytes)
                persistDocument(payload)
                runOnUiThread {
                    // Prefer live MethodChannel reply; if the engine died, Dart will
                    // call takePendingDocument on resume.
                    if (reply != null) {
                        try {
                            reply.success(payload)
                            clearPersistedDocument()
                        } catch (_: Exception) {
                            // Keep persisted payload for takePendingDocument.
                        }
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    if (reply != null) {
                        reply.error(
                            if (e.message?.contains("too large", ignoreCase = true) == true) {
                                "too_large"
                            } else {
                                "copy_failed"
                            },
                            e.message ?: "Unable to read selected file.",
                            null,
                        )
                    }
                }
            }
        }
    }

    private fun copyUriToCache(uri: Uri, maxBytes: Long): HashMap<String, Any> {
        val displayName = queryDisplayName(uri) ?: "document"
        val safeName = sanitizeFileName(displayName)
        val cacheDir = File(cacheDir, "requirement_uploads").apply { mkdirs() }
        // Keep only a few recent picks to avoid filling cache on low storage.
        trimCacheDir(cacheDir, keepNewest = 3)
        val dest = File(cacheDir, "${System.currentTimeMillis()}_$safeName")

        contentResolver.openInputStream(uri)?.use { input ->
            dest.outputStream().use { output ->
                val buffer = ByteArray(32 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    total += read
                    if (total > maxBytes) {
                        dest.delete()
                        throw IOException("File is too large. Max 15 MB.")
                    }
                    output.write(buffer, 0, read)
                }
                output.flush()
            }
        } ?: throw IOException("Unable to open selected file.")

        if (!dest.exists() || dest.length() <= 0L) {
            dest.delete()
            throw IOException("Picked file is empty.")
        }

        return hashMapOf(
            "path" to dest.absolutePath,
            "name" to safeName,
            "size" to dest.length(),
        )
    }

    private fun trimCacheDir(dir: File, keepNewest: Int) {
        val files = dir.listFiles()?.sortedByDescending { it.lastModified() } ?: return
        for (i in keepNewest until files.size) {
            files[i].delete()
        }
    }

    private fun persistDocument(payload: Map<String, Any>) {
        val prefs = getSharedPreferences(DOC_PICKER_PREFS, Context.MODE_PRIVATE)
        prefs.edit()
            .putString("path", payload["path"]?.toString() ?: "")
            .putString("name", payload["name"]?.toString() ?: "")
            .putLong("size", (payload["size"] as? Number)?.toLong() ?: 0L)
            .putLong("ts", System.currentTimeMillis())
            .putBoolean("in_progress", false)
            .apply()
    }

    private fun consumePersistedDocument(): HashMap<String, Any>? {
        val prefs = getSharedPreferences(DOC_PICKER_PREFS, Context.MODE_PRIVATE)
        val path = prefs.getString("path", null)?.trim().orEmpty()
        val ts = prefs.getLong("ts", 0L)
        if (path.isEmpty()) return null
        if (ts > 0L && System.currentTimeMillis() - ts > PENDING_MAX_AGE_MS) {
            clearPersistedDocument()
            File(path).delete()
            return null
        }
        val file = File(path)
        if (!file.exists() || file.length() <= 0L) {
            clearPersistedDocument()
            return null
        }
        val name = prefs.getString("name", null)?.trim().orEmpty()
        val size = prefs.getLong("size", file.length())
        clearPersistedDocument()
        return hashMapOf(
            "path" to path,
            "name" to (if (name.isNotEmpty()) name else file.name),
            "size" to size,
        )
    }

    private fun clearPersistedDocument() {
        getSharedPreferences(DOC_PICKER_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove("path")
            .remove("name")
            .remove("size")
            .remove("ts")
            .apply()
    }

    private fun markPickerInProgress(inProgress: Boolean) {
        getSharedPreferences(DOC_PICKER_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean("in_progress", inProgress)
            .apply()
    }

    private fun queryDisplayName(uri: Uri): String? {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index) else null
            } else {
                null
            }
        } catch (_: Exception) {
            null
        } finally {
            cursor?.close()
        }
    }

    private fun sanitizeFileName(name: String): String {
        val cleaned = name.trim().replace(Regex("[\\\\/:*?\"<>|]"), "_")
        if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") {
            return "document.bin"
        }
        return cleaned.take(120)
    }

    private fun savePublicDownload(call: MethodCall, result: MethodChannel.Result) {
        val fileNameRaw = (call.argument<String>("fileName") ?: "").trim()
        val mimeType = (call.argument<String>("mimeType") ?: "application/octet-stream").trim()
            .ifEmpty { "application/octet-stream" }
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = validateFileName(fileNameRaw)
        if (fileName == null || bytes == null || bytes.isEmpty()) {
            result.error("invalid_args", "fileName and bytes are required.", null)
            return
        }

        try {
            val savedName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                writePublicDownloadScoped(fileName, mimeType, bytes)
            } else {
                writePublicDownloadLegacy(fileName, bytes)
            }
            result.success(
                hashMapOf(
                    "ok" to true,
                    "fileName" to savedName,
                    "directory" to "Download",
                )
            )
        } catch (e: Exception) {
            result.error("write_failed", e.message ?: "Failed to save file to Downloads.", null)
        }
    }

    private fun writePublicDownloadScoped(
        fileName: String,
        mimeType: String,
        bytes: ByteArray,
    ): String {
        val resolver = contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/"
        var displayName = fileName
        var attempt = 0
        var targetUri: Uri? = null

        while (attempt < 20 && targetUri == null) {
            val candidate = if (attempt == 0) {
                fileName
            } else {
                val dot = fileName.lastIndexOf('.')
                if (dot > 0) {
                    "${fileName.substring(0, dot)} ($attempt)${fileName.substring(dot)}"
                } else {
                    "$fileName ($attempt)"
                }
            }

            // Prefer a fresh insert; MediaStore will avoid clobbering existing files.
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, candidate)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            targetUri = resolver.insert(collection, values)
            if (targetUri != null) {
                displayName = candidate
                break
            }
            attempt += 1
        }

        val uri = targetUri ?: throw IOException("Unable to create Downloads entry.")
        resolver.openOutputStream(uri, "w")?.use { output ->
            output.write(bytes)
            output.flush()
        } ?: throw IOException("Unable to open Downloads output stream.")

        val finalizeValues = ContentValues().apply {
            put(MediaStore.MediaColumns.IS_PENDING, 0)
        }
        resolver.update(uri, finalizeValues, null, null)
        return displayName
    }

    private fun writePublicDownloadLegacy(fileName: String, bytes: ByteArray): String {
        val downloadsDir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        if (!downloadsDir.exists()) {
            downloadsDir.mkdirs()
        }

        var target = File(downloadsDir, fileName)
        var attempt = 1
        while (target.exists() && attempt < 20) {
            val dot = fileName.lastIndexOf('.')
            val nextName = if (dot > 0) {
                "${fileName.substring(0, dot)} ($attempt)${fileName.substring(dot)}"
            } else {
                "$fileName ($attempt)"
            }
            target = File(downloadsDir, nextName)
            attempt += 1
        }
        target.writeBytes(bytes)
        return target.name
    }

    private fun writeBackupFileAuto(call: MethodCall, result: MethodChannel.Result) {
        val fileNameRaw = (call.argument<String>("fileName") ?: "").trim()
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = validateFileName(fileNameRaw)
        if (fileName == null || bytes == null || bytes.isEmpty()) {
            result.error("invalid_args", "fileName and bytes are required.", null)
            return
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                writeAutoBackupScoped(fileName, bytes)
            } else {
                writeAutoBackupLegacy(fileName, bytes)
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("write_failed", e.message ?: "Failed to write auto backup file.", null)
        }
    }

    private fun readBackupFileAuto(call: MethodCall, result: MethodChannel.Result) {
        val fileNameRaw = (call.argument<String>("fileName") ?: "").trim()
        val fileName = validateFileName(fileNameRaw)
        if (fileName == null) {
            result.error("invalid_args", "fileName is required.", null)
            return
        }

        try {
            val bytes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                readAutoBackupScoped(fileName)
            } else {
                readAutoBackupLegacy(fileName)
            }
            if (bytes == null) {
                result.success(null)
                return
            }
            result.success(bytes)
        } catch (e: Exception) {
            result.error("read_failed", e.message ?: "Failed to read auto backup file.", null)
        }
    }

    private fun writeAutoBackupScoped(fileName: String, bytes: ByteArray) {
        val resolver = contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$AUTO_BACKUP_FOLDER/"
        var targetUri = findScopedDownloadUri(fileName, relativePath)

        if (targetUri == null) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            targetUri = resolver.insert(collection, values)
        }

        val uri = targetUri ?: throw IOException("Unable to create backup file entry.")
        resolver.openOutputStream(uri, "w")?.use { output ->
            output.write(bytes)
            output.flush()
        } ?: throw IOException("Unable to open output stream for backup file.")

        val finalizeValues = ContentValues().apply {
            put(MediaStore.MediaColumns.IS_PENDING, 0)
        }
        resolver.update(uri, finalizeValues, null, null)
    }

    private fun readAutoBackupScoped(fileName: String): ByteArray? {
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$AUTO_BACKUP_FOLDER/"
        val uri = findScopedDownloadUri(fileName, relativePath) ?: return null
        return contentResolver.openInputStream(uri)?.use { input ->
            input.readBytes()
        }
    }

    private fun findScopedDownloadUri(fileName: String, relativePath: String): android.net.Uri? {
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
        val selectionArgs = arrayOf(fileName, relativePath)

        contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(0)
                return ContentUris.withAppendedId(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    id
                )
            }
        }
        return null
    }

    private fun writeAutoBackupLegacy(fileName: String, bytes: ByteArray) {
        val downloadsDir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        val backupDir = File(downloadsDir, AUTO_BACKUP_FOLDER)
        if (!backupDir.exists()) {
            backupDir.mkdirs()
        }
        val target = File(backupDir, fileName)
        target.writeBytes(bytes)
    }

    private fun readAutoBackupLegacy(fileName: String): ByteArray? {
        val downloadsDir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        val target = File(File(downloadsDir, AUTO_BACKUP_FOLDER), fileName)
        if (!target.exists()) return null
        return target.readBytes()
    }

    private fun validateFileName(fileName: String): String? {
        if (fileName.isEmpty()) return null
        if (fileName.contains("/") || fileName.contains("\\")) return null
        if (fileName == "." || fileName == "..") return null
        return fileName
    }
}
