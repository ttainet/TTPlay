package com.ttai.ttplay.exoplayer

import android.os.SystemClock
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * Tracks rolling network transfer throughput (bytes/sec) across Media3 [DataSource] reads.
 *
 * Uses a fixed 2-second ring buffer of 200 ms buckets so buffering speed reflects recent
 * upstream progress, ramps smoothly from startup, and decays cleanly to 0 B/s on stalls.
 */
@UnstableApi
class TransferSpeedTracker(
  private val clockMs: () -> Long = { SystemClock.elapsedRealtime() }
) : TransferListener {
  private val buckets = LongArray(BUCKET_COUNT)
  private var lastBucketIdx = -1L
  private var windowStartMs = 0L
  private var hasNetworkActivity = false

  override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit

  override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit

  override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit

  @Synchronized
  override fun onBytesTransferred(
    source: DataSource,
    dataSpec: DataSpec,
    isNetwork: Boolean,
    bytesTransferred: Int
  ) {
    if (!isNetwork || bytesTransferred <= 0) return
    val nowMs = clockMs()
    val bucketIdx = advanceBuckets(nowMs)
    if (bucketsSum() == 0L) {
      windowStartMs = nowMs
    }
    hasNetworkActivity = true
    lastBucketIdx = bucketIdx
    val slot = ((bucketIdx % BUCKET_COUNT) + BUCKET_COUNT) % BUCKET_COUNT
    buckets[slot.toInt()] += bytesTransferred.toLong()
  }

  /**
   * Returns current throughput in bytes/sec, `0.0` when a previously active network stream is
   * currently stalled, or `null` when no network bytes have been transferred in this session.
   */
  @Synchronized
  fun bytesPerSecond(): Double? {
    if (!hasNetworkActivity) return null
    val nowMs = clockMs()
    advanceBuckets(nowMs)
    val sum = bucketsSum()
    if (sum <= 0L) return 0.0
    val effectiveWindowMs = (nowMs - windowStartMs + BUCKET_MS).coerceIn(BUCKET_MS, WINDOW_MS)
    return sum * 1000.0 / effectiveWindowMs
  }

  @Synchronized
  fun reset() {
    buckets.fill(0L)
    lastBucketIdx = -1L
    windowStartMs = 0L
    hasNetworkActivity = false
  }

  private fun advanceBuckets(nowMs: Long): Long {
    val bucketIdx = nowMs / BUCKET_MS
    if (lastBucketIdx < 0L) {
      lastBucketIdx = bucketIdx
      return bucketIdx
    }
    val delta = bucketIdx - lastBucketIdx
    if (delta <= 0L) return bucketIdx
    if (delta >= BUCKET_COUNT) {
      buckets.fill(0L)
      windowStartMs = 0L
    } else {
      for (step in 1L..delta) {
        val clearIdx = (((lastBucketIdx + step) % BUCKET_COUNT) + BUCKET_COUNT) % BUCKET_COUNT
        buckets[clearIdx.toInt()] = 0L
      }
    }
    lastBucketIdx = bucketIdx
    return bucketIdx
  }

  private fun bucketsSum(): Long {
    var total = 0L
    for (v in buckets) {
      total += v
    }
    return total
  }

  companion object {
    private const val BUCKET_COUNT = 10
    private const val BUCKET_MS = 200L
    private const val WINDOW_MS = BUCKET_COUNT * BUCKET_MS
  }
}
