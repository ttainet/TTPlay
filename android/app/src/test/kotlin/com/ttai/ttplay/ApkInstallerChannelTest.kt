package com.ttai.ttplay

import android.app.Activity
import android.content.Intent
import android.net.Uri
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.util.zip.GZIPOutputStream

@RunWith(RobolectricTestRunner::class)
class ApkInstallerChannelTest {

  @get:Rule
  val tempFolder = TemporaryFolder()

  @Test
  fun buildInstallIntentConfiguresApkMimeAndFlags() {
    val uri = Uri.parse("content://com.ttai.ttplay.fileprovider/cache/updates/ttplay.apk")
    val intent = ApkInstallerChannel.buildInstallIntent(uri)

    assertEquals(Intent.ACTION_VIEW, intent.action)
    assertEquals(uri, intent.data)
    assertEquals(uri, intent.clipData?.getItemAt(0)?.uri)
    assertEquals("application/vnd.android.package-archive", intent.type)
    assertTrue((intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0)
    assertTrue((intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK) != 0)
  }

  @Test
  fun hasZipMagicValidatesApkHeader() {
    val validApk = tempFolder.newFile("valid.apk")
    validApk.writeBytes(byteArrayOf(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00))

    val invalidApk = tempFolder.newFile("invalid.apk")
    invalidApk.writeBytes(byteArrayOf(0x00, 0x01, 0x02, 0x03, 0x04))

    assertTrue(ApkInstallerChannel.hasZipMagic(validApk))
    assertFalse(ApkInstallerChannel.hasZipMagic(invalidApk))
    assertFalse(ApkInstallerChannel.hasZipMagic(File(tempFolder.root, "missing.apk")))
  }

  @Test
  fun extractApkFromTarGzFileExtractsValidApk() {
    val apkPayload = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x05)
    val archive = tempFolder.newFile("ttplay-android-arm64-v8a.tar.gz")
    writeTarGz(
      archive,
      listOf(
        "README.txt" to "hello".toByteArray(StandardCharsets.UTF_8),
        "ttplay.apk" to apkPayload
      )
    )

    val output = File(tempFolder.root, "out/ttplay.apk")
    val result = ApkInstallerChannel.extractApkFromTarGzFile(archive, output)

    assertEquals(output.absolutePath, result.absolutePath)
    assertTrue(output.isFile)
    assertArrayEquals(apkPayload, output.readBytes())
  }

  @Test(expected = IllegalArgumentException::class)
  fun extractApkFromTarGzFileRejectsArchiveWithoutApk() {
    val archive = tempFolder.newFile("no-apk.tar.gz")
    writeTarGz(archive, listOf("notes.txt" to "plain text".toByteArray(StandardCharsets.UTF_8)))
    val output = File(tempFolder.root, "out/ttplay.apk")

    ApkInstallerChannel.extractApkFromTarGzFile(archive, output)
  }

  @Test
  fun installApkRejectsMissingOrCorruptFile() {
    val activity = Robolectric.buildActivity(Activity::class.java).get()
    val channel = ApkInstallerChannel(activity)
    try {
      val missingResult = RecordingResult()
      val missingMethod = ApkInstallerChannel::class.java.getDeclaredMethod(
        "handleInstallApk",
        io.flutter.plugin.common.MethodCall::class.java,
        io.flutter.plugin.common.MethodChannel.Result::class.java
      )
      missingMethod.isAccessible = true
      missingMethod.invoke(
        channel,
        io.flutter.plugin.common.MethodCall("installApk", mapOf("apkPath" to File(tempFolder.root, "nope.apk").absolutePath)),
        missingResult
      )
      assertEquals("FILE_NOT_FOUND", missingResult.errorCode)

      val corruptFile = tempFolder.newFile("corrupt.apk")
      corruptFile.writeBytes(byteArrayOf(0x41, 0x42, 0x43, 0x44, 0x45))
      val corruptResult = RecordingResult()
      missingMethod.invoke(
        channel,
        io.flutter.plugin.common.MethodCall("installApk", mapOf("apkPath" to corruptFile.absolutePath)),
        corruptResult
      )
      assertEquals("INVALID_APK", corruptResult.errorCode)
    } finally {
      channel.dispose()
    }
  }

  private fun writeTarGz(target: File, entries: List<Pair<String, ByteArray>>) {
    val tarBytes = ByteArrayOutputStream()
    for ((name, content) in entries) {
      val header = ByteArray(512)
      val nameBytes = name.toByteArray(StandardCharsets.UTF_8)
      System.arraycopy(nameBytes, 0, header, 0, minOf(nameBytes.size, 100))
      val mode = "0000644\u0000".toByteArray(StandardCharsets.US_ASCII)
      System.arraycopy(mode, 0, header, 100, mode.size)
      val sizeOctal = content.size.toString(8).padStart(11, '0') + "\u0000"
      val sizeBytes = sizeOctal.toByteArray(StandardCharsets.US_ASCII)
      System.arraycopy(sizeBytes, 0, header, 124, sizeBytes.size)
      header[156] = '0'.code.toByte()
      val ustar = "ustar\u000000".toByteArray(StandardCharsets.US_ASCII)
      System.arraycopy(ustar, 0, header, 257, ustar.size)

      for (i in 148 until 156) header[i] = ' '.code.toByte()
      val checksum = header.sumOf { it.toInt() and 0xFF }
      val checksumStr = checksum.toString(8).padStart(6, '0') + "\u0000 "
      val checksumBytes = checksumStr.toByteArray(StandardCharsets.US_ASCII)
      System.arraycopy(checksumBytes, 0, header, 148, checksumBytes.size)

      tarBytes.write(header)
      tarBytes.write(content)
      val remainder = content.size % 512
      if (remainder != 0) {
        tarBytes.write(ByteArray(512 - remainder))
      }
    }
    tarBytes.write(ByteArray(1024))

    GZIPOutputStream(FileOutputStream(target)).use { gzip ->
      gzip.write(tarBytes.toByteArray())
    }
  }

  private class RecordingResult : io.flutter.plugin.common.MethodChannel.Result {
    var errorCode: String? = null
    override fun success(result: Any?) = Unit
    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
      this.errorCode = errorCode
    }
    override fun notImplemented() = Unit
  }
}
