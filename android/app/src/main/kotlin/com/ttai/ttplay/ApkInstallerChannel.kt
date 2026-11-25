package com.ttai.ttplay

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.zip.GZIPInputStream

internal class ApkInstallerChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.ttai.ttplay/apk_installer"
    private const val TAR_BLOCK_SIZE = 512
    private val ZIP_MAGIC = byteArrayOf(0x50, 0x4B, 0x03, 0x04)

    internal fun canRequestPackageInstalls(activity: Activity): Boolean {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
      return activity.packageManager.canRequestPackageInstalls()
    }

    internal fun buildInstallIntent(uri: Uri): Intent = Intent(Intent.ACTION_VIEW).apply {
      setDataAndType(uri, "application/vnd.android.package-archive")
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    internal fun hasZipMagic(file: File): Boolean {
      if (!file.isFile || file.length() <= ZIP_MAGIC.size) return false
      FileInputStream(file).use { input ->
        val header = ByteArray(ZIP_MAGIC.size)
        if (input.read(header) != ZIP_MAGIC.size) return false
        return header.contentEquals(ZIP_MAGIC)
      }
    }

    internal fun extractApkFromTarGzFile(archiveFile: File, outputFile: File): File {
      if (!archiveFile.isFile) {
        throw IllegalArgumentException("Archive file does not exist: ${archiveFile.absolutePath}")
      }

      outputFile.parentFile?.mkdirs()
      val tempFile = File("${outputFile.absolutePath}.extracting")
      if (tempFile.exists()) tempFile.delete()

      var extracted = false
      try {
        GZIPInputStream(BufferedInputStream(FileInputStream(archiveFile))).use { gzip ->
          val header = ByteArray(TAR_BLOCK_SIZE)
          var pendingLongName: String? = null

          while (readExactOrEof(gzip, header)) {
            if (isAllZero(header)) break

            val size = parseTarOctal(header, 124, 12)
            val typeFlag = (header[156].toInt() and 0xFF).toChar()
            val entryName = pendingLongName ?: parseTarEntryName(header)
            pendingLongName = null

            if (typeFlag == 'L') {
              val nameBytes = ByteArray(size.toInt())
              readFully(gzip, nameBytes)
              skipPadding(gzip, size)
              pendingLongName = String(nameBytes, StandardCharsets.UTF_8).trimEnd('\u0000')
              continue
            }

            val isRegularFile = typeFlag == '0' || typeFlag == '\u0000'
            if (isRegularFile && entryName.lowercase().endsWith(".apk")) {
              FileOutputStream(tempFile).use { output ->
                copyExactBytes(gzip, output, size)
              }
              if (!hasZipMagic(tempFile)) {
                throw IOException("Extracted APK is invalid or corrupted")
              }
              if (outputFile.exists() && !outputFile.delete()) {
                throw IOException("Could not replace existing APK: ${outputFile.absolutePath}")
              }
              if (!tempFile.renameTo(outputFile)) {
                throw IOException("Failed to move extracted APK to ${outputFile.absolutePath}")
              }
              extracted = true
              break
            }

            skipFully(gzip, size)
            skipPadding(gzip, size)
          }
        }

        if (!extracted) {
          throw IllegalArgumentException("Archive does not contain an APK file")
        }
        return outputFile
      } finally {
        if (!extracted && tempFile.exists()) {
          tempFile.delete()
        }
      }
    }

    private fun isAllZero(block: ByteArray): Boolean = block.all { it == 0.toByte() }

    private fun parseTarOctal(header: ByteArray, offset: Int, length: Int): Long {
      val raw = String(header, offset, length, StandardCharsets.US_ASCII)
        .trim('\u0000', ' ')
      if (raw.isEmpty()) return 0L
      return raw.toLong(8)
    }

    private fun parseTarEntryName(header: ByteArray): String {
      val name = parseNullTerminatedString(header, 0, 100)
      val prefix = parseNullTerminatedString(header, 345, 155)
      return if (prefix.isEmpty()) name else "$prefix/$name"
    }

    private fun parseNullTerminatedString(bytes: ByteArray, offset: Int, length: Int): String {
      var end = offset
      val limit = offset + length
      while (end < limit && bytes[end] != 0.toByte()) {
        end++
      }
      return String(bytes, offset, end - offset, StandardCharsets.UTF_8)
    }

    private fun readExactOrEof(input: InputStream, buffer: ByteArray): Boolean {
      var offset = 0
      while (offset < buffer.size) {
        val read = input.read(buffer, offset, buffer.size - offset)
        if (read < 0) {
          if (offset == 0) return false
          throw IOException("Unexpected EOF inside tar header")
        }
        offset += read
      }
      return true
    }

    private fun readFully(input: InputStream, buffer: ByteArray) {
      var offset = 0
      while (offset < buffer.size) {
        val read = input.read(buffer, offset, buffer.size - offset)
        if (read < 0) throw IOException("Unexpected EOF inside tar entry")
        offset += read
      }
    }

    private fun copyExactBytes(input: InputStream, output: FileOutputStream, size: Long) {
      val buffer = ByteArray(16 * 1024)
      var remaining = size
      while (remaining > 0) {
        val toRead = minOf(remaining, buffer.size.toLong()).toInt()
        val read = input.read(buffer, 0, toRead)
        if (read < 0) throw IOException("Unexpected EOF while extracting APK")
        output.write(buffer, 0, read)
        remaining -= read
      }
    }

    private fun skipPadding(input: InputStream, size: Long) {
      val remainder = (size % TAR_BLOCK_SIZE).toInt()
      if (remainder != 0) {
        skipFully(input, (TAR_BLOCK_SIZE - remainder).toLong())
      }
    }

    private fun skipFully(input: InputStream, byteCount: Long) {
      val buffer = ByteArray(8 * 1024)
      var remaining = byteCount
      while (remaining > 0) {
        val toRead = minOf(remaining, buffer.size.toLong()).toInt()
        val read = input.read(buffer, 0, toRead)
        if (read < 0) throw IOException("Unexpected EOF while skipping tar entry")
        remaining -= read
      }
    }
  }

  private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "ttplay-apk-installer").apply { isDaemon = true }
  }

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  fun dispose() {
    executor.shutdownNow()
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "canRequestPackageInstalls" -> result.success(canRequestPackageInstalls(activity))
      "openUnknownSourcesSettings" -> result.success(openUnknownSourcesSettings())
      "extractApkFromTarGz" -> handleExtractApkFromTarGz(call, result)
      "installApk" -> handleInstallApk(call, result)
      else -> result.notImplemented()
    }
  }

  private fun openUnknownSourcesSettings(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
    val packageUri = Uri.parse("package:${activity.packageName}")
    val manageIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, packageUri).apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    try {
      activity.startActivity(manageIntent)
      return true
    } catch (_: ActivityNotFoundException) {
      val appDetailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      return try {
        activity.startActivity(appDetailsIntent)
        true
      } catch (_: ActivityNotFoundException) {
        false
      }
    }
  }

  private fun handleExtractApkFromTarGz(call: MethodCall, result: MethodChannel.Result) {
    val archivePath = call.argument<String>("archivePath")
    val outputPath = call.argument<String>("outputPath")
    if (archivePath.isNullOrBlank() || outputPath.isNullOrBlank()) {
      result.error("INVALID_ARGUMENT", "archivePath and outputPath are required", null)
      return
    }

    try {
      executor.execute {
        try {
          val outputFile = extractApkFromTarGzFile(File(archivePath), File(outputPath))
          activity.runOnUiThread { result.success(outputFile.absolutePath) }
        } catch (error: Exception) {
          activity.runOnUiThread {
            result.error("EXTRACT_FAILED", error.message ?: error.javaClass.simpleName, null)
          }
        }
      }
    } catch (error: Exception) {
      result.error("EXTRACT_FAILED", error.message ?: error.javaClass.simpleName, null)
    }
  }

  private fun handleInstallApk(call: MethodCall, result: MethodChannel.Result) {
    val apkPath = call.argument<String>("apkPath")
    if (apkPath.isNullOrBlank()) {
      result.error("INVALID_ARGUMENT", "apkPath is required", null)
      return
    }

    val file = File(apkPath)
    if (!file.isFile) {
      result.error("FILE_NOT_FOUND", "APK file not found: $apkPath", null)
      return
    }
    if (!hasZipMagic(file)) {
      result.error("INVALID_APK", "Downloaded file is not a valid APK", null)
      return
    }

    if (!canRequestPackageInstalls(activity)) {
      result.success(mapOf("status" to "permission_required"))
      return
    }

    try {
      val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
      activity.startActivity(buildInstallIntent(uri))
      result.success(mapOf("status" to "launched"))
    } catch (error: Exception) {
      result.error("INSTALL_FAILED", error.message ?: error.javaClass.simpleName, null)
    }
  }
}
