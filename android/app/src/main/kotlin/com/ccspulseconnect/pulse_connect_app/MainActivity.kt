package com.ccspulseconnect.pulse_connect_app

import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
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

class MainActivity : FlutterActivity() {
    companion object {
        private const val OFFLINE_BACKUP_CHANNEL = "pulseconnect/offline_backup"
        private const val DOCUMENT_PICKER_CHANNEL = "pulseconnect/document_picker"
        private const val AUTO_BACKUP_FOLDER = "PulseConnect"
        private const val REQUEST_PICK_DOCUMENT = 0x5043 // 'PC'
        private const val DEFAULT_MAX_BYTES = 15L * 1024L * 1024L
    }

    private var pendingDocumentResult: MethodChannel.Result? = null
    private var pendingMaxBytes: Long = DEFAULT_MAX_BYTES

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
                else -> result.notImplemented()
            }
        }
    }

    private fun pickDocument(call: MethodCall, result: MethodChannel.Result) {
        if (pendingDocumentResult != null) {
            result.error("busy", "A file picker is already open.", null)
            return
        }

        pendingMaxBytes = when (val raw = call.argument<Any>("maxBytes")) {
            is Number -> raw.toLong().coerceAtLeast(1024L)
            else -> DEFAULT_MAX_BYTES
        }
        pendingDocumentResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
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
            pendingDocumentResult = null
            result.error("picker_failed", e.message ?: "Unable to open file picker.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_PICK_DOCUMENT) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val reply = pendingDocumentResult
        pendingDocumentResult = null
        if (reply == null) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            reply.success(null)
            return
        }

        try {
            val uri = data.data!!
            val displayName = queryDisplayName(uri) ?: "document"
            val safeName = sanitizeFileName(displayName)
            val cacheDir = File(cacheDir, "requirement_uploads").apply { mkdirs() }
            val dest = File(cacheDir, "${System.currentTimeMillis()}_$safeName")

            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        total += read
                        if (total > pendingMaxBytes) {
                            dest.delete()
                            reply.error(
                                "too_large",
                                "File is too large. Max 15 MB.",
                                null,
                            )
                            return
                        }
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                }
            } ?: throw IOException("Unable to open selected file.")

            reply.success(
                hashMapOf(
                    "path" to dest.absolutePath,
                    "name" to safeName,
                    "size" to dest.length(),
                ),
            )
        } catch (e: Exception) {
            reply.error("copy_failed", e.message ?: "Unable to read selected file.", null)
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(uri, null, null, null, null)
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
