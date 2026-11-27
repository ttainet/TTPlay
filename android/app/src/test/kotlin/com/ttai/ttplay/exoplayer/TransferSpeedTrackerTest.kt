package com.ttai.ttplay.exoplayer

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@OptIn(UnstableApi::class)
@RunWith(RobolectricTestRunner::class)
class TransferSpeedTrackerTest {
  private val dummySource = ByteArrayDataSource(ByteArray(16))
  private val dummySpec = DataSpec(Uri.parse("http://127.0.0.1/test.mkv"))

  @Test
  fun ignoresNonNetworkTransfers() {
    var nowMs = 1000L
    val tracker = TransferSpeedTracker { nowMs }

    tracker.onBytesTransferred(dummySource, dummySpec, isNetwork = false, bytesTransferred = 512 * 1024)
    assertNull(tracker.bytesPerSecond())
  }

  @Test
  fun computesRollingThroughputDecaysToZeroOnStallAndResets() {
    var nowMs = 1000L
    val tracker = TransferSpeedTracker { nowMs }

    // 256 KiB in the first 200 ms bucket -> effectiveWindow = 200 ms -> 1,310,720 B/s
    tracker.onBytesTransferred(dummySource, dummySpec, isNetwork = true, bytesTransferred = 256 * 1024)
    assertEquals(256 * 1024 * 1000.0 / 200.0, tracker.bytesPerSecond()!!, 1.0)

    // Total 2 MiB across [1000..2000] ms -> effectiveWindow = 1200 ms
    nowMs = 2000L
    tracker.onBytesTransferred(dummySource, dummySpec, isNetwork = true, bytesTransferred = 1792 * 1024)
    assertEquals(2048 * 1024 * 1000.0 / 1200.0, tracker.bytesPerSecond()!!, 1.0)

    // Stall for > 2s clears rolling window and reports 0.0 B/s (stream stalled)
    nowMs = 5000L
    assertEquals(0.0, tracker.bytesPerSecond()!!, 0.001)

    // New transfer after stall starts a fresh window without under-reporting over 2s
    tracker.onBytesTransferred(dummySource, dummySpec, isNetwork = true, bytesTransferred = 500_000)
    assertEquals(500_000 * 1000.0 / 200.0, tracker.bytesPerSecond()!!, 1.0)

    // Reset returns to null until network bytes arrive again
    tracker.reset()
    assertNull(tracker.bytesPerSecond())
  }
}
